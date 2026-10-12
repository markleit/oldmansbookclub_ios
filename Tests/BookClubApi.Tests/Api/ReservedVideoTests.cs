using System.Net;
using System.Text;
using System.Text.Json;
using BookClubApi.Models;
using BookClubApi.Tests.Infrastructure;
using Microsoft.EntityFrameworkCore;

namespace BookClubApi.Tests.Api;

/// #204 design v2 — a video send completes without the app (docs/SEND_REQUIREMENTS.md V1–V9). The
/// app reserves the message and uploads the file straight to storage; storage's "file landed"
/// report (Event Grid → /storage/events) makes the server create the message itself.
public class ReservedVideoTests(TestAppFixture fixture) : IntegrationTestBase(fixture)
{
    private async Task<(Club Club, Book Book, TestUser Sender)> ArrangeAsync()
    {
        var club = await CreateClubAsync();
        var book = await CreateBookAsync(club.Id, "The Road");
        var sender = await CreateUserAsync("Mark", club.Id);
        return (club, book, sender);
    }

    private static Task<HttpResponseMessage> ReserveAsync(TestUser user, Guid bookId, Guid clientId,
        DateTime? sentAt = null, Guid? parentId = null) =>
        user.Client.PostAsync($"/books/{bookId}/messages/video", JsonBody(new
        {
            client_id = clientId,
            parent_message_id = parentId,
            device_id = "senders-phone",
            sent_at = sentAt
        }));

    /// What Event Grid posts when a blob lands (its own camelCase schema, not the API's).
    private Task<HttpResponseMessage> StorageReportsAsync(string blobUrl) =>
        App.CreateClient().PostAsync("/storage/events", new StringContent(JsonSerializer.Serialize(new[]
        {
            new
            {
                id = Guid.NewGuid().ToString(),
                eventType = "Microsoft.Storage.BlobCreated",
                subject = "/blobServices/default/containers/club-media/blobs/x.mp4",
                eventTime = DateTime.UtcNow,
                data = new { api = "PutBlob", contentType = "video/mp4", contentLength = 1234, blobType = "BlockBlob", url = blobUrl }
            }
        }), Encoding.UTF8, "application/json"));

    /// The app's own post after its upload — what every older client does, and a current one that's
    /// running when the upload finishes.
    private static Task<HttpResponseMessage> PostVideoAsync(TestUser user, Guid bookId, Guid clientId, string mediaUrl) =>
        user.Client.PostAsync($"/books/{bookId}/messages", JsonBody(new
        {
            type = "Video",
            media_url = mediaUrl,
            client_id = clientId,
            device_id = "senders-phone"
        }));

    private async Task<List<Message>> MessagesAsync()
    {
        await using var db = App.NewDbContext();
        return await db.Messages.ToListAsync();
    }

    private async Task<int> PendingCountAsync()
    {
        await using var db = App.NewDbContext();
        return await db.PendingVideos.CountAsync();
    }

    [Fact]
    public async Task V1_reserving_a_video_gives_an_upload_link_that_lasts_as_long_as_the_send_token()
    {
        var (_, book, sender) = await ArrangeAsync();

        var reservation = await ReadAsync<VideoReservation>(await ReserveAsync(sender, book.Id, Guid.NewGuid()));

        Assert.NotNull(reservation.UploadUrl);
        Assert.StartsWith($"https://{FakeBlobService.Host}/club-media/{book.ClubId}/", reservation.MediaUrl);
        Assert.Null(reservation.Message);
        // A video handed to iOS can wait for the network as long as the send token lets the
        // message wait: an upload link that ran out sooner would strand it.
        Assert.InRange(Blob.LastVideoUploadLinkValidity!.Value.TotalDays, 6.9, 7.0);
        Assert.Empty(await MessagesAsync());
    }

    [Fact]
    public async Task V2_when_the_upload_lands_the_server_creates_the_message_without_the_app()
    {
        var (_, book, sender) = await ArrangeAsync();
        var parent = await InsertMessageAsync(book.Id, book.ClubId, sender.Id);
        var clientId = Guid.NewGuid();
        var tappedAt = DateTime.UtcNow.AddMinutes(-5);
        var reservation = await ReadAsync<VideoReservation>(await ReserveAsync(sender, book.Id, clientId, tappedAt, parent.Id));
        DrainPushes();

        Blob.Land(reservation.MediaUrl!);
        var report = await StorageReportsAsync(reservation.MediaUrl + "?ignored=query");

        Assert.Equal(HttpStatusCode.OK, report.StatusCode);
        var video = (await MessagesAsync()).Single(m => m.Type == MessageType.Video);
        Assert.Equal(clientId, video.ClientId);
        Assert.Equal(sender.Id, video.SenderId);
        Assert.Equal(reservation.MediaUrl, video.MediaUrl);
        Assert.Equal(parent.Id, video.ParentMessageId);
        // Ordered by when it was tapped, not when the upload finished (O3).
        Assert.InRange((video.SentAt - tappedAt).Duration().TotalSeconds, 0, 1);
        // Delivered like any send: the chat hears it, the members get one push, the sender's own
        // phone is skipped.
        Assert.Contains(Hub.OfMethod("NewMessage"), b => b.Arg<MessageDto>(0).Id == video.Id);
        Assert.Equal("senders-phone", Assert.Single(DrainPushes()).SenderDeviceToken);
        Assert.Equal(0, await PendingCountAsync());
    }

    [Fact]
    public async Task V3_the_report_then_the_apps_own_post_make_one_message()
    {
        var (_, book, sender) = await ArrangeAsync();
        var clientId = Guid.NewGuid();
        var reservation = await ReadAsync<VideoReservation>(await ReserveAsync(sender, book.Id, clientId));
        Blob.Land(reservation.MediaUrl!);

        await StorageReportsAsync(reservation.MediaUrl!);
        var posted = await ReadAsync<MessageDto>(await PostVideoAsync(sender, book.Id, clientId, reservation.MediaUrl!));

        Assert.Equal(Assert.Single(await MessagesAsync()).Id, posted.Id);
        Assert.Single(DrainPushes());
    }

    [Fact]
    public async Task V4_the_apps_own_post_then_the_report_make_one_message()
    {
        var (_, book, sender) = await ArrangeAsync();
        var clientId = Guid.NewGuid();
        var reservation = await ReadAsync<VideoReservation>(await ReserveAsync(sender, book.Id, clientId));
        Blob.Land(reservation.MediaUrl!);

        await ReadAsync<MessageDto>(await PostVideoAsync(sender, book.Id, clientId, reservation.MediaUrl!));
        Assert.Equal(0, await PendingCountAsync());
        Hub.Clear();
        var report = await StorageReportsAsync(reservation.MediaUrl!);

        Assert.Equal(HttpStatusCode.OK, report.StatusCode);
        Assert.Single(await MessagesAsync());
        Assert.Single(DrainPushes());
        Assert.Empty(Hub.OfMethod("NewMessage"));
    }

    [Fact]
    public async Task V5_a_report_is_not_trusted_without_the_file_in_storage()
    {
        var (_, book, sender) = await ArrangeAsync();
        var reservation = await ReadAsync<VideoReservation>(await ReserveAsync(sender, book.Id, Guid.NewGuid()));

        await StorageReportsAsync(reservation.MediaUrl!);
        Assert.Empty(await MessagesAsync());
        Assert.Equal(1, await PendingCountAsync());

        Blob.Land(reservation.MediaUrl!);
        await StorageReportsAsync(reservation.MediaUrl!);
        Assert.Single(await MessagesAsync());
    }

    [Fact]
    public async Task V6_a_report_of_a_file_nobody_reserved_changes_nothing()
    {
        // An older client's video, a voice or photo file, or a forged report.
        var (_, book, sender) = await ArrangeAsync();
        var unreserved = $"https://{FakeBlobService.Host}/club-media/{book.ClubId}/{Guid.NewGuid()}.mp4";
        Blob.Land(unreserved);

        var report = await StorageReportsAsync(unreserved);

        Assert.Equal(HttpStatusCode.OK, report.StatusCode);
        Assert.Empty(await MessagesAsync());
        Assert.Empty(DrainPushes());
    }

    [Fact]
    public async Task V7_reserving_again_reuses_the_file_and_once_sent_returns_the_message()
    {
        var (_, book, sender) = await ArrangeAsync();
        var clientId = Guid.NewGuid();

        var first = await ReadAsync<VideoReservation>(await ReserveAsync(sender, book.Id, clientId));
        var again = await ReadAsync<VideoReservation>(await ReserveAsync(sender, book.Id, clientId));
        Assert.Equal(first.MediaUrl, again.MediaUrl);
        Assert.NotNull(again.UploadUrl);

        Blob.Land(first.MediaUrl!);
        await StorageReportsAsync(first.MediaUrl!);
        var afterSent = await ReadAsync<VideoReservation>(await ReserveAsync(sender, book.Id, clientId));

        // Nothing to upload: the app is told it's sent, so it doesn't upload the video twice.
        Assert.Null(afterSent.UploadUrl);
        Assert.Equal(Assert.Single(await MessagesAsync()).Id, afterSent.Message!.Id);
    }

    [Fact]
    public async Task V8_whoever_cant_send_there_is_refused_before_uploading()
    {
        var (_, book, _) = await ArrangeAsync();
        var outsider = await CreateUserAsync("Outsider", (await CreateClubAsync("Other club")).Id);

        var response = await ReserveAsync(outsider, book.Id, Guid.NewGuid());

        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
        Assert.Contains("Not a member of this club.", await response.Content.ReadAsStringAsync());
        Assert.Equal(0, await PendingCountAsync());
    }

    [Fact]
    public async Task V9_a_video_too_large_is_not_created_and_the_apps_post_says_why()
    {
        var (_, book, sender) = await ArrangeAsync();
        var clientId = Guid.NewGuid();
        var reservation = await ReadAsync<VideoReservation>(await ReserveAsync(sender, book.Id, clientId));
        Blob.NextBlobSize = 101L * 1024 * 1024;
        Blob.Land(reservation.MediaUrl!);

        await StorageReportsAsync(reservation.MediaUrl!);
        Assert.Empty(await MessagesAsync());
        Assert.Equal(0, await PendingCountAsync());

        var posted = await PostVideoAsync(sender, book.Id, clientId, reservation.MediaUrl!);
        Assert.Equal(HttpStatusCode.BadRequest, posted.StatusCode);
        Assert.Contains("Video is too large (max 100 MB).", await posted.Content.ReadAsStringAsync());
    }

    [Fact]
    public async Task V10_a_reserved_video_counts_once_against_the_send_limit()
    {
        var (_, book, sender) = await ArrangeAsync();
        var clientId = Guid.NewGuid();
        var reservation = await ReadAsync<VideoReservation>(await ReserveAsync(sender, book.Id, clientId));
        var limiter = App.Services.GetService(typeof(BookClubApi.Services.HubRateLimiter)) as BookClubApi.Services.HubRateLimiter;
        while (limiter!.TryAcquire(sender.Id)) { }

        // Its own post, and a re-reservation, are the same send: not refused.
        await ReadAsync<VideoReservation>(await ReserveAsync(sender, book.Id, clientId));
        Blob.Land(reservation.MediaUrl!);
        await ReadAsync<MessageDto>(await PostVideoAsync(sender, book.Id, clientId, reservation.MediaUrl!));

        // A new video is.
        Assert.Equal(HttpStatusCode.TooManyRequests, (await ReserveAsync(sender, book.Id, Guid.NewGuid())).StatusCode);
    }

    [Fact]
    public async Task V11_event_grids_subscription_handshake_is_answered()
    {
        var response = await App.CreateClient().PostAsync("/storage/events", new StringContent(JsonSerializer.Serialize(new[]
        {
            new
            {
                id = Guid.NewGuid().ToString(),
                eventType = "Microsoft.EventGrid.SubscriptionValidationEvent",
                data = new { validationCode = "512d38b6-c7b8-40c8-89fe-f46f9e9622b6", validationUrl = "https://example.invalid" }
            }
        }), Encoding.UTF8, "application/json"));

        var body = JsonDocument.Parse(await response.Content.ReadAsStringAsync()).RootElement;
        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        Assert.Equal("512d38b6-c7b8-40c8-89fe-f46f9e9622b6", body.GetProperty("validationResponse").GetString());
    }
}
