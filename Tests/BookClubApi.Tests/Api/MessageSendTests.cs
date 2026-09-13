using System.Net;
using System.Net.Http.Json;
using BookClubApi.Models;
using BookClubApi.Tests.Infrastructure;
using Microsoft.EntityFrameworkCore;

namespace BookClubApi.Tests.Api;

/// The send path — the single highest-blast-radius code in the API. Every one of these assertions
/// corresponds to a behaviour a shipped bug has already depended on (#35, #131, #146, and the dev
/// media-send outage that #120's storage split caused).
public class MessageSendTests(TestAppFixture fixture) : IntegrationTestBase(fixture)
{
    private async Task<(Club Club, Book Book, TestUser Sender)> ArrangeAsync()
    {
        var club = await CreateClubAsync();
        var book = await CreateBookAsync(club.Id, "The Road");
        var sender = await CreateUserAsync("Mark", club.Id);
        return (club, book, sender);
    }

    private static object TextSend(Guid clientId, string body = "hello") => new
    {
        type = "Text",
        body,
        media_url = (string?)null,
        duration_seconds = (int?)null,
        client_id = clientId,
        parent_message_id = (Guid?)null,
        device_id = (string?)null
    };

    // ---- clientId dedup ---------------------------------------------------------------------

    [Fact]
    public async Task Resending_the_same_clientId_creates_one_message_and_broadcasts_once()
    {
        var (_, book, sender) = await ArrangeAsync();
        var clientId = Guid.NewGuid();

        var first = await sender.Client.PostAsJsonAsync($"/books/{book.Id}/messages", TextSend(clientId));
        var second = await sender.Client.PostAsJsonAsync($"/books/{book.Id}/messages", TextSend(clientId));

        var a = await ReadAsync<MessageDto>(first);
        var b = await ReadAsync<MessageDto>(second);

        // Same message handed back both times — this is what lets a client retry a send whose
        // response it never saw without the user ending up with two bubbles.
        Assert.Equal(a.Id, b.Id);

        await using var db = App.NewDbContext();
        Assert.Equal(1, await db.Messages.CountAsync());

        // Exactly one PUSH. This, not the row count, is the assertion that matters: a duplicate
        // push is what a user would actually experience, and it is guarded by `alreadyBroadcast`
        // — separate machinery from the unique index that keeps the row count at one.
        Assert.Single(DrainPushes());

        // The re-broadcast, by contrast, is deliberate and must NOT be asserted away. A client
        // retrying a send whose response it never received needs the message delivered again;
        // every client dedups by message id on receipt (ChatCache.merge). Pinning it at two
        // records that intent, so a future "optimisation" that suppresses it has to be a
        // conscious decision rather than a silent one.
        Assert.Equal(2, Hub.OfMethod("NewMessage").Count());
    }

    [Fact]
    public async Task Concurrent_sends_with_the_same_clientId_resolve_to_one_winner()
    {
        var (_, book, sender) = await ArrangeAsync();
        var clientId = Guid.NewGuid();

        // Both requests pass the pre-check before either has inserted, so one of them loses the
        // insert race and must recover via the SqlException 2601/2627 path rather than 500ing.
        // This is the test that cannot run on SQLite or the in-memory provider: without the real
        // filtered unique index there is no race to lose, and it would pass while proving nothing.
        var responses = await Task.WhenAll(
            sender.Client.PostAsJsonAsync($"/books/{book.Id}/messages", TextSend(clientId)),
            sender.Client.PostAsJsonAsync($"/books/{book.Id}/messages", TextSend(clientId)));

        var dtos = new List<MessageDto>();
        foreach (var response in responses) dtos.Add(await ReadAsync<MessageDto>(response));

        Assert.Equal(dtos[0].Id, dtos[1].Id);

        await using var db = App.NewDbContext();
        Assert.Equal(1, await db.Messages.CountAsync());

        // One push no matter which of the two orderings the race takes (both pre-check and miss,
        // or one pre-check hit). Broadcast count is 1 or 2 depending on that ordering, so pinning
        // it exactly would make this test flaky for a reason unrelated to the invariant.
        Assert.Single(DrainPushes());
        Assert.InRange(Hub.OfMethod("NewMessage").Count(), 1, 2);
    }

    [Fact]
    public async Task Distinct_clientIds_are_two_messages()
    {
        var (_, book, sender) = await ArrangeAsync();

        await sender.Client.PostAsJsonAsync($"/books/{book.Id}/messages", TextSend(Guid.NewGuid(), "one"));
        await sender.Client.PostAsJsonAsync($"/books/{book.Id}/messages", TextSend(Guid.NewGuid(), "two"));

        await using var db = App.NewDbContext();
        Assert.Equal(2, await db.Messages.CountAsync());
        Assert.Equal(2, Hub.OfMethod("NewMessage").Count());
    }

    // ---- validation -------------------------------------------------------------------------

    [Theory]
    [InlineData("")]
    [InlineData("   ")]
    public async Task Blank_text_is_refused(string body)
    {
        var (_, book, sender) = await ArrangeAsync();

        var response = await sender.Client.PostAsJsonAsync($"/books/{book.Id}/messages", TextSend(Guid.NewGuid(), body));

        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
        Assert.Empty(Hub.OfMethod("NewMessage"));
    }

    [Fact]
    public async Task Text_longer_than_4000_characters_is_refused()
    {
        var (_, book, sender) = await ArrangeAsync();

        var ok = await sender.Client.PostAsJsonAsync($"/books/{book.Id}/messages", TextSend(Guid.NewGuid(), new string('a', 4000)));
        var tooLong = await sender.Client.PostAsJsonAsync($"/books/{book.Id}/messages", TextSend(Guid.NewGuid(), new string('a', 4001)));

        Assert.True(ok.IsSuccessStatusCode);
        Assert.Equal(HttpStatusCode.BadRequest, tooLong.StatusCode);
    }

    [Fact]
    public async Task Media_url_on_a_foreign_host_is_refused()
    {
        var (club, book, sender) = await ArrangeAsync();

        var response = await sender.Client.PostAsJsonAsync($"/books/{book.Id}/messages", new
        {
            type = "Voice",
            media_url = $"https://attacker.example.com/club-media/{club.Id}/whatever.m4a",
            duration_seconds = 5,
            client_id = Guid.NewGuid()
        });

        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
    }

    [Fact]
    public async Task Media_url_on_our_own_host_is_accepted()
    {
        // The mirror of the test above, and the one that matters more: this check was hardcoded to
        // production's storage account, so when #120 gave dev its own account, every dev voice,
        // photo and video send failed with "Invalid media URL." A test that only proved rejection
        // would have stayed green through that entire outage.
        var (club, book, sender) = await ArrangeAsync();

        var response = await sender.Client.PostAsJsonAsync($"/books/{book.Id}/messages", new
        {
            type = "Voice",
            media_url = $"https://{FakeBlobService.Host}/club-media/{club.Id}/{Guid.NewGuid()}.m4a",
            duration_seconds = 5,
            client_id = Guid.NewGuid()
        });

        var dto = await ReadAsync<MessageDto>(response);
        Assert.Equal(MessageType.Voice, dto.Type);
        // Broadcast carries a freshly signed URL, never the bare stored one — a stored SAS would
        // expire and break playback for everyone.
        Assert.Contains("?sig=", dto.MediaUrl);
    }

    [Fact]
    public async Task Oversized_media_is_refused_by_the_server_side_cap()
    {
        var (club, book, sender) = await ArrangeAsync();
        Blob.NextBlobSize = 26L * 1024 * 1024;   // over the 25 MB voice cap

        var response = await sender.Client.PostAsJsonAsync($"/books/{book.Id}/messages", new
        {
            type = "Voice",
            media_url = $"https://{FakeBlobService.Host}/club-media/{club.Id}/{Guid.NewGuid()}.m4a",
            duration_seconds = 5,
            client_id = Guid.NewGuid()
        });

        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
    }

    // ---- authorization ----------------------------------------------------------------------

    [Fact]
    public async Task A_non_member_cannot_send_to_a_club_they_are_not_in()
    {
        var (_, book, _) = await ArrangeAsync();
        var outsider = await CreateUserAsync("Outsider");   // no membership

        var response = await outsider.Client.PostAsJsonAsync($"/books/{book.Id}/messages", TextSend(Guid.NewGuid()));

        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
        await using var db = App.NewDbContext();
        Assert.Equal(0, await db.Messages.CountAsync());
    }

    [Fact]
    public async Task An_unapproved_account_cannot_send()
    {
        var club = await CreateClubAsync();
        var book = await CreateBookAsync(club.Id, "The Road");
        var pending = await CreateUserAsync("Pending", club.Id, approved: false);

        var response = await pending.Client.PostAsJsonAsync($"/books/{book.Id}/messages", TextSend(Guid.NewGuid()));

        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
    }

    // ---- rate limiting ----------------------------------------------------------------------

    [Fact]
    public async Task The_thirty_first_send_in_a_window_is_refused()
    {
        var (_, book, sender) = await ArrangeAsync();

        for (var i = 0; i < 30; i++)
        {
            var ok = await sender.Client.PostAsJsonAsync($"/books/{book.Id}/messages", TextSend(Guid.NewGuid(), $"msg {i}"));
            Assert.True(ok.IsSuccessStatusCode, $"send {i} was refused: {await ok.Content.ReadAsStringAsync()}");
        }

        var refused = await sender.Client.PostAsJsonAsync($"/books/{book.Id}/messages", TextSend(Guid.NewGuid(), "one too many"));

        Assert.Equal(HttpStatusCode.BadRequest, refused.StatusCode);
        Assert.Contains("Slow down", await refused.Content.ReadAsStringAsync());
    }

    // ---- push hand-off ----------------------------------------------------------------------

    [Fact]
    public async Task A_successful_send_queues_exactly_one_push_job()
    {
        var (_, book, sender) = await ArrangeAsync();

        await sender.Client.PostAsJsonAsync($"/books/{book.Id}/messages", TextSend(Guid.NewGuid()));

        var jobs = DrainPushes();
        var job = Assert.Single(jobs);
        Assert.Equal(book.Id, job.BookId);
        Assert.Equal("The Road", job.BookTitle);
    }

    [Fact]
    public async Task A_refused_send_queues_no_push()
    {
        var (_, book, sender) = await ArrangeAsync();

        await sender.Client.PostAsJsonAsync($"/books/{book.Id}/messages", TextSend(Guid.NewGuid(), ""));

        Assert.Empty(DrainPushes());
    }
}
