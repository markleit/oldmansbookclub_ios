using System.Net.Http.Json;
using System.Text.Json;
using BookClubApi.Models;
using BookClubApi.Services;
using BookClubApi.Tests.Infrastructure;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging.Abstractions;

namespace BookClubApi.Tests.Api;

/// The push fan-out, end to end up to the APNs socket.
///
/// Real delivery needs a physical device and is covered by the device lane. Everything BEFORE the
/// socket — who receives it, which device is excluded, the alert text, the badge number, the
/// per-book unread — is ordinary server logic, and asserting it here means the device lane only
/// has to answer "did the notification arrive", not "was it correct".
///
/// The dispatch worker is removed from the shared test host (it would drain the queue underneath
/// other tests' assertions), so these tests run their own instance against the same services.
public class PushDispatchTests(TestAppFixture fixture) : IntegrationTestBase(fixture)
{
    private async Task<List<JsonElement>> DispatchAndCollectAsync(int expected)
    {
        var worker = new NotificationDispatchService(
            App.Services.GetRequiredService<IServiceScopeFactory>(),
            PushQueue,
            App.Services.GetRequiredService<NotificationService>(),
            NullLogger<NotificationDispatchService>.Instance);

        await worker.StartAsync(CancellationToken.None);
        try
        {
            // The worker reads from a channel on its own thread; poll rather than sleep a fixed
            // amount, so this is neither flaky on a slow CI runner nor slow on a fast one.
            var deadline = DateTime.UtcNow.AddSeconds(10);
            while (Apns.Requests.Count < expected && DateTime.UtcNow < deadline)
                await Task.Delay(25);
            await Task.Delay(100);   // let any unexpected extra push land, so over-sending fails too
        }
        finally
        {
            await worker.StopAsync(CancellationToken.None);
        }

        return [.. Apns.Requests.Select(r => JsonDocument.Parse(r.Body).RootElement)];
    }

    private async Task<(Club Club, Book Book, TestUser Sender, TestUser Recipient)> ArrangeAsync()
    {
        var club = await CreateClubAsync();
        var book = await CreateBookAsync(club.Id, "The Road");
        var sender = await CreateUserAsync("Mark", club.Id);
        var recipient = await CreateUserAsync("Dixie", club.Id);
        await RegisterDeviceAsync(recipient.Id, "recipient-device");
        return (club, book, sender, recipient);
    }

    [Fact]
    public async Task A_text_message_pushes_the_other_members_with_sender_name_and_body()
    {
        var (_, book, sender, _) = await ArrangeAsync();

        await sender.Client.PostAsJsonAsync($"/books/{book.Id}/messages",
            new { type = "Text", body = "have you got to chapter nine yet", client_id = Guid.NewGuid() });

        var payloads = await DispatchAndCollectAsync(1);

        var aps = Assert.Single(payloads).GetProperty("aps");
        Assert.Equal("The Road", aps.GetProperty("alert").GetProperty("title").GetString());
        Assert.Equal("Mark: have you got to chapter nine yet", aps.GetProperty("alert").GetProperty("body").GetString());
        Assert.Equal(1, aps.GetProperty("badge").GetInt32());
        Assert.Equal(1, aps.GetProperty("content-available").GetInt32());
    }

    [Fact]
    public async Task A_long_body_is_truncated_in_the_alert()
    {
        var (_, book, sender, _) = await ArrangeAsync();
        var body = new string('x', 200);

        await sender.Client.PostAsJsonAsync($"/books/{book.Id}/messages",
            new { type = "Text", body, client_id = Guid.NewGuid() });

        var payloads = await DispatchAndCollectAsync(1);

        var alert = payloads[0].GetProperty("aps").GetProperty("alert").GetProperty("body").GetString()!;
        Assert.EndsWith("…", alert);
        Assert.Equal($"Mark: {new string('x', 60)}…", alert);
    }

    [Fact]
    public async Task A_voice_message_says_so_rather_than_leaking_a_url()
    {
        var (club, book, sender, _) = await ArrangeAsync();

        await sender.Client.PostAsJsonAsync($"/books/{book.Id}/messages", new
        {
            type = "Voice",
            media_url = $"https://{FakeBlobService.Host}/club-media/{club.Id}/{Guid.NewGuid()}.m4a",
            duration_seconds = 5,
            client_id = Guid.NewGuid()
        });

        var payloads = await DispatchAndCollectAsync(1);

        var alert = payloads[0].GetProperty("aps").GetProperty("alert").GetProperty("body").GetString();
        Assert.Equal("Mark sent a voice message", alert);
    }

    [Fact]
    public async Task The_badge_and_per_book_unread_are_the_recipients_numbers_not_the_senders()
    {
        var (club, book, sender, recipient) = await ArrangeAsync();
        var second = await CreateBookAsync(club.Id, "Another Book");
        await InsertMessageAsync(second.Id, club.Id, sender.Id);   // already unread for the recipient

        await sender.Client.PostAsJsonAsync($"/books/{book.Id}/messages",
            new { type = "Text", body = "hello", client_id = Guid.NewGuid() });

        var payloads = await DispatchAndCollectAsync(1);

        // Badge = everything unread across every book (2); bookUnread = this book only (1). The
        // client sets the book's count from bookUnread EXACTLY rather than incrementing, so the
        // two numbers must mean different things and both be right (#119).
        Assert.Equal(2, payloads[0].GetProperty("aps").GetProperty("badge").GetInt32());
        Assert.Equal(1, payloads[0].GetProperty("bookUnread").GetInt32());
    }

    [Fact]
    public async Task The_sending_device_is_excluded_but_the_senders_other_devices_are_not()
    {
        // #25: a multi-device user should see their own message arrive on their iPad. Only the
        // device that actually sent it is skipped — excluding the whole sender was the old
        // behaviour, and it left the sender's other devices silently out of sync.
        var (_, book, sender, _) = await ArrangeAsync();
        await RegisterDeviceAsync(sender.Id, "senders-phone");
        await RegisterDeviceAsync(sender.Id, "senders-ipad");

        await sender.Client.PostAsJsonAsync($"/books/{book.Id}/messages",
            new { type = "Text", body = "hello", client_id = Guid.NewGuid(), device_id = "senders-phone" });

        await DispatchAndCollectAsync(2);

        var tokens = Apns.Requests.Select(r => r.Request.RequestUri!.AbsolutePath.Split('/').Last()).ToHashSet();
        Assert.Contains("recipient-device", tokens);
        Assert.Contains("senders-ipad", tokens);
        Assert.DoesNotContain("senders-phone", tokens);
    }

    [Fact]
    public async Task A_member_with_no_registered_device_is_simply_skipped()
    {
        var (club, book, sender, _) = await ArrangeAsync();
        await CreateUserAsync("Never Signed In On A Phone", club.Id);

        await sender.Client.PostAsJsonAsync($"/books/{book.Id}/messages",
            new { type = "Text", body = "hello", client_id = Guid.NewGuid() });

        await DispatchAndCollectAsync(1);

        Assert.Single(Apns.Requests);
    }

    [Fact]
    public async Task Members_of_other_clubs_are_not_pushed()
    {
        var (_, book, sender, _) = await ArrangeAsync();
        var otherClub = await CreateClubAsync("Someone Else's Club");
        var stranger = await CreateUserAsync("Stranger", otherClub.Id);
        await RegisterDeviceAsync(stranger.Id, "stranger-device");

        await sender.Client.PostAsJsonAsync($"/books/{book.Id}/messages",
            new { type = "Text", body = "hello", client_id = Guid.NewGuid() });

        await DispatchAndCollectAsync(1);

        var tokens = Apns.Requests.Select(r => r.Request.RequestUri!.AbsolutePath.Split('/').Last()).ToList();
        Assert.Equal(["recipient-device"], tokens);
    }

    [Fact]
    public async Task The_push_carries_the_ids_a_woken_client_needs()
    {
        var (club, book, sender, _) = await ArrangeAsync();

        var response = await sender.Client.PostAsJsonAsync($"/books/{book.Id}/messages",
            new { type = "Text", body = "hello", client_id = Guid.NewGuid() });
        var sent = await ReadAsync<MessageDto>(response);

        var payloads = await DispatchAndCollectAsync(1);

        // A background-woken client uses these to fetch the message straight into its chat cache.
        Assert.Equal(club.Id.ToString(), payloads[0].GetProperty("clubId").GetString());
        Assert.Equal(book.Id.ToString(), payloads[0].GetProperty("bookId").GetString());
        Assert.Equal(sent.Id.ToString(), payloads[0].GetProperty("messageId").GetString());
    }
}
