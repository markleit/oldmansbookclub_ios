using System.Net;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using BookClubApi.Models;
using BookClubApi.Services;
using BookClubApi.Tests.Infrastructure;
using Microsoft.EntityFrameworkCore;

namespace BookClubApi.Tests.Api;

/// #204 design v2 — upload slots (docs/SEND_REQUIREMENTS.md VS1–VS7): upload links fetched in
/// advance, so a video sent with no network can be handed to iOS at the tap. The message's details
/// travel with the upload as metadata; the server creates the message when storage reports it.
public class VideoSlotTests(TestAppFixture fixture) : IntegrationTestBase(fixture)
{
    private async Task<(Club Club, Book Book, TestUser Sender)> ArrangeAsync()
    {
        var club = await CreateClubAsync();
        var book = await CreateBookAsync(club.Id, "The Road");
        var sender = await CreateUserAsync("Mark", club.Id);
        return (club, book, sender);
    }

    private static async Task<List<VideoSlot>> SlotsAsync(HttpClient client, Guid clubId, int count = 3)
    {
        var response = await client.PostAsync($"/media/video-slots?clubId={clubId}&count={count}", null);
        return [.. (await ReadAsync<VideoSlotsResponse>(response)).Slots];
    }

    /// What the app sends with a slot upload (x-ms-meta-* headers), as storage keeps it.
    private static Dictionary<string, string> Details(Guid bookId, Guid clientId, DateTime? sentAt = null, Guid? parentId = null) => new()
    {
        [MessageSendService.SlotMetadata.BookId] = bookId.ToString(),
        [MessageSendService.SlotMetadata.ClientId] = clientId.ToString(),
        [MessageSendService.SlotMetadata.SentAt] = (sentAt ?? DateTime.UtcNow).ToString("O"),
        [MessageSendService.SlotMetadata.DeviceId] = "senders-phone",
        [MessageSendService.SlotMetadata.ParentId] = parentId?.ToString() ?? "",
    };

    private Task<HttpResponseMessage> StorageReportsAsync(string blobUrl) =>
        App.CreateClient().PostAsync("/storage/events", new StringContent(JsonSerializer.Serialize(new[]
        {
            new { id = Guid.NewGuid().ToString(), eventType = "Microsoft.Storage.BlobCreated", data = new { url = blobUrl } }
        }), Encoding.UTF8, "application/json"));

    private async Task<List<Message>> MessagesAsync()
    {
        await using var db = App.NewDbContext();
        return await db.Messages.ToListAsync();
    }

    [Fact]
    public async Task VS1_slots_are_create_only_links_good_for_a_week_up_to_ten_at_once()
    {
        var (club, _, sender) = await ArrangeAsync();

        var slots = await SlotsAsync(sender.Client, club.Id);

        Assert.Equal(3, slots.Count);
        Assert.All(slots, s => Assert.StartsWith($"https://{FakeBlobService.Host}/club-media/{club.Id}/", s.MediaUrl));
        Assert.Equal(3, slots.Select(s => s.MediaUrl).Distinct().Count());
        Assert.All(slots, s => Assert.InRange((s.ExpiresAt - DateTime.UtcNow).TotalDays, 6.9, 7.0));
        Assert.InRange(Blob.LastVideoUploadLinkValidity!.Value.TotalDays, 6.9, 7.0);
        Assert.Empty(await MessagesAsync());

        // Capped: a buggy or hostile client can't stockpile them.
        Assert.Equal(7, (await SlotsAsync(sender.Client, club.Id, 20)).Count);
        Assert.Empty(await SlotsAsync(sender.Client, club.Id, 3));
    }

    [Fact]
    public async Task VS1_only_for_a_club_you_belong_to()
    {
        var (_, _, sender) = await ArrangeAsync();
        var other = await CreateClubAsync("Other club");

        var response = await sender.Client.PostAsync($"/media/video-slots?clubId={other.Id}", null);

        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
        Assert.Contains("Not a member of this club.", await response.Content.ReadAsStringAsync());
    }

    [Fact]
    public async Task VS2_a_slot_upload_becomes_its_message_when_it_lands()
    {
        var (_, book, sender) = await ArrangeAsync();
        var parent = await InsertMessageAsync(book.Id, book.ClubId, sender.Id);
        var slot = (await SlotsAsync(sender.Client, book.ClubId))[0];
        var clientId = Guid.NewGuid();
        var tappedAt = DateTime.UtcNow.AddMinutes(-3);
        DrainPushes();

        Blob.Land(slot.MediaUrl, Details(book.Id, clientId, tappedAt, parent.Id));
        await StorageReportsAsync(slot.MediaUrl);

        var video = (await MessagesAsync()).Single(m => m.Type == MessageType.Video);
        Assert.Equal((clientId, sender.Id, slot.MediaUrl, parent.Id, book.Id),
            (video.ClientId!.Value, video.SenderId, video.MediaUrl!, video.ParentMessageId!.Value, video.BookId));
        Assert.InRange((video.SentAt - tappedAt).Duration().TotalSeconds, 0, 1);
        Assert.Contains(Hub.OfMethod("NewMessage"), b => b.Arg<MessageDto>(0).Id == video.Id);
        Assert.Equal("senders-phone", Assert.Single(DrainPushes()).SenderDeviceToken);
        await using var db = App.NewDbContext();
        Assert.False(await db.PendingVideos.AnyAsync(p => p.MediaUrl == slot.MediaUrl), "the slot is used up");
    }

    [Fact]
    public async Task VS3_an_upload_without_proper_details_or_for_another_clubs_book_creates_nothing()
    {
        var (_, book, sender) = await ArrangeAsync();
        // Another club the sender is ALSO in: membership alone wouldn't stop it, the club check must.
        var foreignClub = await CreateClubAsync("Other club");
        var foreignBook = await CreateBookAsync(foreignClub.Id, "Elsewhere");
        await using (var db = App.NewDbContext())
        {
            db.Memberships.Add(new Membership { UserId = sender.Id, ClubId = foreignClub.Id });
            await db.SaveChangesAsync();
        }
        var slots = await SlotsAsync(sender.Client, book.ClubId);

        Blob.Land(slots[0].MediaUrl, new Dictionary<string, string> { ["clientid"] = Guid.NewGuid().ToString() });   // no book
        Blob.Land(slots[1].MediaUrl, Details(foreignBook.Id, Guid.NewGuid()));   // stored under this club, says another
        Blob.Land(slots[2].MediaUrl, new Dictionary<string, string> { ["bookid"] = "nonsense", ["clientid"] = "x" });
        foreach (var slot in slots) Assert.Equal(HttpStatusCode.OK, (await StorageReportsAsync(slot.MediaUrl)).StatusCode);

        Assert.Empty(await MessagesAsync());
    }

    [Fact]
    public async Task VS4_signing_out_drops_what_a_slot_would_create()
    {
        var signIn = await ReadAsync<JsonElement>(await App.CreateClient().PostAsync("/auth/apple", JsonBody(new
        {
            identity_token = "any-token-the-validator-is-faked", display_name = "Mark", club_name = "Club"
        })));
        Guid clubId, bookId;
        await using (var db = App.NewDbContext())
        {
            clubId = (await db.Clubs.SingleAsync()).Id;
            bookId = (await CreateBookAsync(clubId, "The Road")).Id;
        }
        var send = App.CreateClient();
        send.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", signIn.GetProperty("send_token").GetString());
        var slots = await SlotsAsync(send, clubId, 2);   // fetched with the send token: tied to this sign-in

        Blob.Land(slots[0].MediaUrl, Details(bookId, Guid.NewGuid()));
        await StorageReportsAsync(slots[0].MediaUrl);
        Assert.Single(await MessagesAsync());

        var access = App.CreateClient();
        access.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", signIn.GetProperty("access_token").GetString());
        await access.PostAsync("/auth/logout", JsonBody(new { refresh_token = signIn.GetProperty("refresh_token").GetString() }));
        Blob.Land(slots[1].MediaUrl, Details(bookId, Guid.NewGuid()));
        await StorageReportsAsync(slots[1].MediaUrl);

        Assert.Single(await MessagesAsync());
    }

    [Fact]
    public async Task VS5_the_report_and_the_apps_own_post_make_one_message_whichever_comes_first()
    {
        var (_, book, sender) = await ArrangeAsync();
        var slots = await SlotsAsync(sender.Client, book.ClubId, 2);

        // The report first, then the app's post confirming it…
        var first = Guid.NewGuid();
        Blob.Land(slots[0].MediaUrl, Details(book.Id, first));
        await StorageReportsAsync(slots[0].MediaUrl);
        var confirmed = await ReadAsync<MessageDto>(await sender.Client.PostAsync($"/books/{book.Id}/messages",
            JsonBody(new { type = "Video", media_url = slots[0].MediaUrl, client_id = first })));
        // …and the post first, then the report.
        var second = Guid.NewGuid();
        Blob.Land(slots[1].MediaUrl, Details(book.Id, second));
        await ReadAsync<MessageDto>(await sender.Client.PostAsync($"/books/{book.Id}/messages",
            JsonBody(new { type = "Video", media_url = slots[1].MediaUrl, client_id = second })));
        await StorageReportsAsync(slots[1].MediaUrl);

        var messages = await MessagesAsync();
        Assert.Equal(2, messages.Count);
        Assert.Contains(messages, m => m.Id == confirmed.Id && m.ClientId == first);
        Assert.Single(messages, m => m.ClientId == second);
    }

    [Fact]
    public async Task VS6_the_apps_post_of_a_slot_video_isnt_counted_against_the_send_limit()
    {
        var (_, book, sender) = await ArrangeAsync();
        var slot = (await SlotsAsync(sender.Client, book.ClubId, 1))[0];
        var limiter = App.Services.GetService(typeof(HubRateLimiter)) as HubRateLimiter;
        while (limiter!.TryAcquire(sender.Id)) { }

        var posted = await sender.Client.PostAsync($"/books/{book.Id}/messages",
            JsonBody(new { type = "Video", media_url = slot.MediaUrl, client_id = Guid.NewGuid() }));

        Assert.True(posted.IsSuccessStatusCode, await posted.Content.ReadAsStringAsync());
    }

    [Fact]
    public async Task VS7_unused_slots_are_dropped_after_eight_days()
    {
        var (_, book, sender) = await ArrangeAsync();
        var old = (await SlotsAsync(sender.Client, book.ClubId, 1))[0];
        await using (var db = App.NewDbContext())
        {
            var row = await db.PendingVideos.SingleAsync();
            row.CreatedAt = DateTime.UtcNow.AddDays(-8.5);
            await db.SaveChangesAsync();
        }

        await SlotsAsync(sender.Client, book.ClubId, 1);   // any request tidies up

        await using var check = App.NewDbContext();
        Assert.False(await check.PendingVideos.AnyAsync(p => p.MediaUrl == old.MediaUrl));
        Blob.Land(old.MediaUrl, Details(book.Id, Guid.NewGuid()));
        await StorageReportsAsync(old.MediaUrl);
        Assert.Empty(await MessagesAsync());
    }
}
