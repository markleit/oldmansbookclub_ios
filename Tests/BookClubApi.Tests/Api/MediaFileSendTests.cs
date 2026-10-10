using System.Net;
using System.Net.Http.Headers;
using BookClubApi.Models;
using BookClubApi.Tests.Infrastructure;
using Microsoft.EntityFrameworkCore;

namespace BookClubApi.Tests.Api;

/// #204 — the one-request voice/photo send: the file is the body of POST /books/{id}/messages,
/// and the server stores it and creates the message. This is what lets a 2.2 client hand a send to
/// iOS at tap time and have iOS finish it with the app asleep, so every refusal must happen BEFORE
/// the bytes are stored (a refused send leaves nothing behind) and a re-send must never store or
/// announce the message twice.
public class MediaFileSendTests(TestAppFixture fixture) : IntegrationTestBase(fixture)
{
    private static readonly byte[] VoiceBytes = [0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70, 0x4D, 0x34, 0x41, 0x20];
    private static readonly byte[] JpegBytes = [0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46];

    private async Task<(Club Club, Book Book, TestUser Sender)> ArrangeAsync()
    {
        var club = await CreateClubAsync();
        var book = await CreateBookAsync(club.Id, "The Road");
        var sender = await CreateUserAsync("Mark", club.Id);
        return (club, book, sender);
    }

    private static Task<HttpResponseMessage> SendFileAsync(HttpClient client, Guid bookId, byte[] bytes,
        string contentType, Guid? clientId, int? durationSeconds = null, Guid? parentId = null)
    {
        var query = new List<string>();
        if (clientId is Guid c) query.Add($"client_id={c}");
        if (durationSeconds is int d) query.Add($"duration_seconds={d}");
        if (parentId is Guid p) query.Add($"parent_message_id={p}");
        var content = new ByteArrayContent(bytes);
        content.Headers.ContentType = new MediaTypeHeaderValue(contentType);
        return client.PostAsync($"/books/{bookId}/messages?{string.Join("&", query)}", content);
    }

    private async Task<int> MessageCountAsync()
    {
        await using var db = App.NewDbContext();
        return await db.Messages.CountAsync();
    }

    // ---- the happy paths --------------------------------------------------------------------

    [Fact]
    public async Task A_voice_file_is_stored_once_and_becomes_one_message()
    {
        var (club, book, sender) = await ArrangeAsync();
        var clientId = Guid.NewGuid();

        var dto = await ReadAsync<MessageDto>(await SendFileAsync(sender.Client, book.Id, VoiceBytes, "audio/mp4", clientId, 42));

        Assert.Equal(MessageType.Voice, dto.Type);
        Assert.Equal(42, dto.DurationSeconds);
        Assert.Equal(clientId, dto.ClientId);
        // The response carries a freshly signed URL, like every other media send.
        Assert.Contains("?sig=", dto.MediaUrl);

        var upload = Assert.Single(Blob.Uploads);
        Assert.Equal(VoiceBytes, upload.Bytes);
        Assert.Equal("audio/mp4", upload.ContentType);
        // Named like an upload-link blob, so every downstream check treats both paths the same.
        Assert.StartsWith($"https://{FakeBlobService.Host}/club-media/{club.Id}/", upload.Url);
        Assert.EndsWith(".m4a", upload.Url);

        await using var db = App.NewDbContext();
        var stored = await db.Messages.SingleAsync();
        Assert.Equal(upload.Url, stored.MediaUrl);   // the plain URL is stored, never a SAS

        Assert.Single(Hub.OfMethod("NewMessage"));
        Assert.Single(DrainPushes());
    }

    [Fact]
    public async Task A_photo_file_is_stored_once_and_becomes_one_message()
    {
        var (_, book, sender) = await ArrangeAsync();
        var parent = await InsertMessageAsync(book.Id, book.ClubId, sender.Id, body: "look at this");

        var dto = await ReadAsync<MessageDto>(
            await SendFileAsync(sender.Client, book.Id, JpegBytes, "image/jpeg", Guid.NewGuid(), parentId: parent.Id));

        Assert.Equal(MessageType.Photo, dto.Type);
        Assert.Null(dto.DurationSeconds);
        Assert.Equal(parent.Id, dto.ParentMessageId);
        var upload = Assert.Single(Blob.Uploads);
        Assert.Equal(JpegBytes, upload.Bytes);
        Assert.Equal("image/jpeg", upload.ContentType);
        Assert.EndsWith(".jpg", upload.Url);
        Assert.Single(DrainPushes());
    }

    // ---- re-sends ---------------------------------------------------------------------------

    [Fact]
    public async Task Resending_the_same_clientId_returns_the_message_without_storing_the_file_again()
    {
        // The direct and background copies of one send, or a retry whose response was lost.
        var (_, book, sender) = await ArrangeAsync();
        var clientId = Guid.NewGuid();

        var first = await ReadAsync<MessageDto>(await SendFileAsync(sender.Client, book.Id, VoiceBytes, "audio/mp4", clientId, 5));
        var second = await ReadAsync<MessageDto>(await SendFileAsync(sender.Client, book.Id, VoiceBytes, "audio/mp4", clientId, 5));

        Assert.Equal(first.Id, second.Id);
        Assert.Single(Blob.Uploads);          // the second body was never stored
        Assert.Equal(1, await MessageCountAsync());
        Assert.Single(DrainPushes());         // and nobody was notified twice
    }

    [Fact]
    public async Task Concurrent_copies_of_one_send_resolve_to_one_message_and_clean_up_the_loser()
    {
        var (_, book, sender) = await ArrangeAsync();
        var clientId = Guid.NewGuid();

        var responses = await Task.WhenAll(
            SendFileAsync(sender.Client, book.Id, VoiceBytes, "audio/mp4", clientId, 5),
            SendFileAsync(sender.Client, book.Id, VoiceBytes, "audio/mp4", clientId, 5));
        var ids = new List<Guid>();
        foreach (var r in responses) ids.Add((await ReadAsync<MessageDto>(r)).Id);

        Assert.Equal(ids[0], ids[1]);
        Assert.Equal(1, await MessageCountAsync());
        Assert.Single(DrainPushes());

        // If both got past the dedup check, both stored a file and the loser's must be deleted;
        // either way exactly one stored file is still referenced.
        await using var db = App.NewDbContext();
        var kept = (await db.Messages.SingleAsync()).MediaUrl;
        Assert.Equal(Blob.Uploads.Count - 1, Blob.Deleted.Count);
        Assert.DoesNotContain(kept, Blob.Deleted);
    }

    // ---- refusals: nothing stored -----------------------------------------------------------

    [Fact]
    public async Task A_non_member_is_refused_and_nothing_is_stored()
    {
        var (_, book, _) = await ArrangeAsync();
        var outsider = await CreateUserAsync("Outsider");

        var response = await SendFileAsync(outsider.Client, book.Id, VoiceBytes, "audio/mp4", Guid.NewGuid(), 5);

        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
        Assert.Empty(Blob.Uploads);
        Assert.Equal(0, await MessageCountAsync());
    }

    [Fact]
    public async Task An_unapproved_account_is_refused_and_nothing_is_stored()
    {
        var club = await CreateClubAsync();
        var book = await CreateBookAsync(club.Id, "The Road");
        var pending = await CreateUserAsync("Pending", club.Id, approved: false);

        var response = await SendFileAsync(pending.Client, book.Id, JpegBytes, "image/jpeg", Guid.NewGuid());

        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
        Assert.Empty(Blob.Uploads);
    }

    [Fact]
    public async Task An_unknown_book_is_refused_and_nothing_is_stored()
    {
        var (_, _, sender) = await ArrangeAsync();

        var response = await SendFileAsync(sender.Client, Guid.NewGuid(), JpegBytes, "image/jpeg", Guid.NewGuid());

        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
        Assert.Contains("Book not found", await response.Content.ReadAsStringAsync());
        Assert.Empty(Blob.Uploads);
    }

    [Fact]
    public async Task A_photo_over_the_cap_is_refused_and_nothing_is_kept()
    {
        var (_, book, sender) = await ArrangeAsync();
        var tooBig = new byte[15 * 1024 * 1024 + 1];   // photo cap is 15 MB

        var response = await SendFileAsync(sender.Client, book.Id, tooBig, "image/jpeg", Guid.NewGuid());

        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
        Assert.Contains("too large", await response.Content.ReadAsStringAsync());
        Assert.Empty(Blob.Uploads);
        Assert.Equal(0, await MessageCountAsync());
    }

    [Fact]
    public async Task A_body_with_no_declared_length_is_still_capped_while_it_streams()
    {
        // Chunked transfer declares no Content-Length, so the up-front check can't see the size —
        // the cap has to hold during the copy, or a client could stream an unbounded file.
        var (_, book, sender) = await ArrangeAsync();
        var content = new StreamContent(new UnknownLengthStream(new byte[15 * 1024 * 1024 + 1]));
        content.Headers.ContentType = new MediaTypeHeaderValue("image/jpeg");
        var request = new HttpRequestMessage(HttpMethod.Post, $"/books/{book.Id}/messages?client_id={Guid.NewGuid()}")
        {
            Content = content
        };
        request.Headers.TransferEncodingChunked = true;

        var response = await sender.Client.SendAsync(request);

        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
        Assert.Contains("too large", await response.Content.ReadAsStringAsync());
        Assert.Empty(Blob.Uploads);
        Assert.Equal(0, await MessageCountAsync());
    }

    [Fact]
    public async Task An_empty_file_is_refused()
    {
        var (_, book, sender) = await ArrangeAsync();

        var response = await SendFileAsync(sender.Client, book.Id, [], "audio/mp4", Guid.NewGuid(), 5);

        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
        Assert.Empty(Blob.Uploads);
    }

    [Fact]
    public async Task A_missing_client_id_is_refused_with_a_reason()
    {
        var (_, book, sender) = await ArrangeAsync();

        var response = await SendFileAsync(sender.Client, book.Id, VoiceBytes, "audio/mp4", clientId: null, 5);

        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
        Assert.Contains("client_id", await response.Content.ReadAsStringAsync());
        Assert.Empty(Blob.Uploads);
    }

    [Theory]
    [InlineData("video/mp4")]    // video stays on the upload-link path (#204: too big to proxy)
    [InlineData("text/plain")]
    public async Task Any_other_file_type_is_not_accepted(string contentType)
    {
        var (_, book, sender) = await ArrangeAsync();

        var response = await SendFileAsync(sender.Client, book.Id, VoiceBytes, contentType, Guid.NewGuid());

        Assert.Equal(HttpStatusCode.UnsupportedMediaType, response.StatusCode);
        Assert.Empty(Blob.Uploads);
        Assert.Equal(0, await MessageCountAsync());
    }

    [Fact]
    public async Task The_json_send_is_unchanged_alongside_the_file_send()
    {
        // Every pre-2.2 client sends JSON to this same URL; adding a second body format must not
        // change which action JSON lands on.
        var (club, book, sender) = await ArrangeAsync();

        var response = await sender.Client.PostAsync($"/books/{book.Id}/messages", JsonBody(new
        {
            type = "Voice",
            media_url = $"https://{FakeBlobService.Host}/club-media/{club.Id}/{Guid.NewGuid()}.m4a",
            duration_seconds = 5,
            client_id = Guid.NewGuid()
        }));

        Assert.Equal(MessageType.Voice, (await ReadAsync<MessageDto>(response)).Type);
        Assert.Empty(Blob.Uploads);
    }

    /// A body whose length can't be known up front, so HttpClient can't send a Content-Length and
    /// the server's only defence is the streaming cap.
    private sealed class UnknownLengthStream(byte[] bytes) : Stream
    {
        private readonly MemoryStream _inner = new(bytes);
        public override bool CanRead => true;
        public override bool CanSeek => false;
        public override bool CanWrite => false;
        public override long Length => throw new NotSupportedException();
        public override long Position { get => _inner.Position; set => throw new NotSupportedException(); }
        public override int Read(byte[] buffer, int offset, int count) => _inner.Read(buffer, offset, count);
        public override void Flush() { }
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    }
}
