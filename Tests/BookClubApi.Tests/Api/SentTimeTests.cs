using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;
using BookClubApi.Models;
using BookClubApi.Tests.Infrastructure;
using Microsoft.EntityFrameworkCore;

namespace BookClubApi.Tests.Api;

/// #204 — ordering by when the sender tapped Send, counting by when the server got it.
///
/// A 2.2 client stamps every message with its tap time (`sent_at`) and sends in parallel, so the
/// chat keeps tap order however the sends race, and a message held up by an outage lands where it
/// was said. That makes two times per message: SentAt orders the chat; ReceivedAt decides what's
/// new to a reader (unread, read marker, push, late arrivals). Mixing them up is exactly how a
/// late message would be silently counted as already read.
public class SentTimeTests(TestAppFixture fixture) : IntegrationTestBase(fixture)
{
    private async Task<(Club Club, Book Book, TestUser Me, TestUser Other)> ArrangeAsync()
    {
        var club = await CreateClubAsync();
        var book = await CreateBookAsync(club.Id, "The Road");
        var me = await CreateUserAsync("Me", club.Id);
        var other = await CreateUserAsync("Other", club.Id);
        return (club, book, me, other);
    }

    private static Task<HttpResponseMessage> SendTextAsync(TestUser user, Guid bookId, DateTime? sentAt, string body = "hello") =>
        user.Client.PostAsJsonAsync($"/books/{bookId}/messages",
            new { type = "Text", body, client_id = Guid.NewGuid(), sent_at = sentAt });

    private static void AssertClose(DateTime expected, DateTime? actual, double seconds = 5)
    {
        Assert.NotNull(actual);
        Assert.InRange(Math.Abs((actual!.Value - expected).TotalSeconds), 0, seconds);
    }

    private static async Task<int> UnreadAsync(TestUser user, Guid bookId)
    {
        var books = await ReadAsync<JsonElement>(await user.Client.GetAsync("/books"));
        return books.EnumerateArray().Single(b => b.GetProperty("id").GetGuid() == bookId).GetProperty("unread_count").GetInt32();
    }

    // ---- the tap time and its clamp (A13) ---------------------------------------------------

    [Fact]
    public async Task A_tap_time_inside_the_window_is_kept_and_the_arrival_is_stamped_separately()
    {
        var (_, book, me, _) = await ArrangeAsync();
        var tapped = DateTime.UtcNow.AddHours(-2);

        var dto = await ReadAsync<MessageDto>(await SendTextAsync(me, book.Id, tapped));

        AssertClose(tapped, dto.SentAt, 0.01);
        AssertClose(DateTime.UtcNow, dto.ReceivedAt);
    }

    [Fact]
    public async Task No_tap_time_means_sent_when_received_as_for_every_older_client()
    {
        var (_, book, me, _) = await ArrangeAsync();

        var dto = await ReadAsync<MessageDto>(await SendTextAsync(me, book.Id, sentAt: null));

        Assert.Equal(dto.ReceivedAt, dto.SentAt);
    }

    [Fact]
    public async Task A_tap_time_in_the_future_is_pulled_back_to_the_arrival()
    {
        var (_, book, me, _) = await ArrangeAsync();

        var dto = await ReadAsync<MessageDto>(await SendTextAsync(me, book.Id, DateTime.UtcNow.AddHours(3)));

        Assert.Equal(dto.ReceivedAt, dto.SentAt);
    }

    [Fact]
    public async Task A_tap_time_older_than_seven_days_is_pulled_forward_to_seven_days()
    {
        var (_, book, me, _) = await ArrangeAsync();

        var dto = await ReadAsync<MessageDto>(await SendTextAsync(me, book.Id, DateTime.UtcNow.AddDays(-90)));

        Assert.Equal(dto.ReceivedAt!.Value.AddDays(-7), dto.SentAt);
    }

    [Fact]
    public async Task The_file_send_takes_the_tap_time_from_the_query()
    {
        var (_, book, me, _) = await ArrangeAsync();
        var tapped = DateTime.UtcNow.AddMinutes(-45);
        var content = new ByteArrayContent([0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70]);
        content.Headers.ContentType = new MediaTypeHeaderValue("audio/mp4");

        var dto = await ReadAsync<MessageDto>(await me.Client.PostAsync(
            $"/books/{book.Id}/messages?client_id={Guid.NewGuid()}&duration_seconds=3&sent_at={Uri.EscapeDataString(tapped.ToString("O"))}",
            content));

        AssertClose(tapped, dto.SentAt, 0.01);
    }

    [Fact]
    public async Task A_forward_takes_the_tap_time_too()
    {
        var (club, book, me, other) = await ArrangeAsync();
        var original = await InsertMessageAsync(book.Id, club.Id, other.Id);
        await using (var db = App.NewDbContext())
        {
            db.SavedMessages.Add(new SavedMessage { UserId = me.Id, MessageId = original.Id });
            await db.SaveChangesAsync();
        }
        var tapped = DateTime.UtcNow.AddMinutes(-20);

        var dto = await ReadAsync<MessageDto>(await me.Client.PostAsJsonAsync($"/books/{book.Id}/messages",
            new { type = "Text", client_id = Guid.NewGuid(), forward_message_id = original.Id, sent_at = tapped }));

        AssertClose(tapped, dto.SentAt, 0.01);
    }

    // ---- received_at on every shape (A14) ---------------------------------------------------

    [Fact]
    public async Task Received_at_is_on_the_send_response_the_broadcast_and_the_history()
    {
        var (_, book, me, other) = await ArrangeAsync();

        var sent = await ReadAsync<MessageDto>(await SendTextAsync(other, book.Id, DateTime.UtcNow.AddMinutes(-30)));

        // The broadcast object is in memory (sub-millisecond); the wire carries milliseconds.
        var broadcast = Hub.OfMethod("NewMessage").Single().Arg<MessageDto>(0);
        AssertClose(sent.ReceivedAt!.Value, broadcast.ReceivedAt, 0.001);

        var history = await me.Client.GetAsync($"/books/{book.Id}/messages");
        var row = (await ReadAsync<JsonElement>(history)).EnumerateArray().Single();
        // Asserted on the raw wire name: the iOS client decodes `received_at` with
        // convertFromSnakeCase, so the name is half of the contract.
        Assert.Equal(sent.ReceivedAt, row.GetProperty("received_at").GetDateTime());
    }

    // ---- unread and the read marker count by arrival (A15, A16) ----------------------------

    [Fact]
    public async Task A_late_arrival_is_unread_even_though_it_was_sent_before_what_you_read()
    {
        var (club, book, me, other) = await ArrangeAsync();
        var read = await InsertMessageAsync(book.Id, club.Id, other.Id, sentAt: DateTime.UtcNow.AddMinutes(-10));
        await me.Client.PostAsJsonAsync($"/books/{book.Id}/read", read.Id);
        Assert.Equal(0, await UnreadAsync(me, book.Id));

        await SendTextAsync(other, book.Id, DateTime.UtcNow.AddMinutes(-30), "written in the tunnel");

        Assert.Equal(1, await UnreadAsync(me, book.Id));
    }

    [Fact]
    public async Task Reading_a_late_arrival_moves_the_marker_and_clears_it()
    {
        var (club, book, me, other) = await ArrangeAsync();
        var read = await InsertMessageAsync(book.Id, club.Id, other.Id, sentAt: DateTime.UtcNow.AddMinutes(-10));
        await me.Client.PostAsJsonAsync($"/books/{book.Id}/read", read.Id);
        var late = await ReadAsync<MessageDto>(await SendTextAsync(other, book.Id, DateTime.UtcNow.AddMinutes(-30)));

        await me.Client.PostAsJsonAsync($"/books/{book.Id}/read", late.Id);

        Assert.Equal(0, await UnreadAsync(me, book.Id));
        await using var db = App.NewDbContext();
        Assert.Equal(late.Id, (await db.ChatReads.SingleAsync(cr => cr.UserId == me.Id)).LastSeenMessageId);
    }

    [Fact]
    public async Task The_marker_does_not_rewind_to_an_earlier_arrival_with_a_later_send_time()
    {
        // The mirror case: marker on the late arrival (received last); re-marking the on-time
        // message (sent later, received earlier) is a rewind by arrival and must be ignored.
        var (club, book, me, other) = await ArrangeAsync();
        var onTime = await InsertMessageAsync(book.Id, club.Id, other.Id, sentAt: DateTime.UtcNow.AddMinutes(-10));
        var late = await ReadAsync<MessageDto>(await SendTextAsync(other, book.Id, DateTime.UtcNow.AddMinutes(-30)));
        await me.Client.PostAsJsonAsync($"/books/{book.Id}/read", late.Id);

        await me.Client.PostAsJsonAsync($"/books/{book.Id}/read", onTime.Id);

        await using var db = App.NewDbContext();
        Assert.Equal(late.Id, (await db.ChatReads.SingleAsync(cr => cr.UserId == me.Id)).LastSeenMessageId);
    }

    // ---- late arrivals on load (A17) --------------------------------------------------------

    private async Task<List<Guid>> LoadIdsAsync(TestUser user, Guid bookId, string query)
    {
        var rows = await ReadAsync<JsonElement>(await user.Client.GetAsync($"/books/{bookId}/messages?{query}"));
        return [.. rows.EnumerateArray().Select(r => r.GetProperty("id").GetGuid())];
    }

    [Fact]
    public async Task Late_arrivals_outside_the_newest_page_come_back_only_when_asked_for()
    {
        var (club, book, me, other) = await ArrangeAsync();
        var now = DateTime.UtcNow;
        var page = new List<Message>();
        for (var i = 3; i >= 1; i--)
            page.Add(await InsertMessageAsync(book.Id, club.Id, other.Id, sentAt: now.AddMinutes(-i)));
        // Sent an hour ago, arrived just now: below the 3-message page.
        var late = await InsertMessageAsync(book.Id, club.Id, other.Id, sentAt: now.AddHours(-1), receivedAt: now);
        // Old and on time — not a late arrival, must stay paged away.
        var oldOnTime = await InsertMessageAsync(book.Id, club.Id, other.Id, sentAt: now.AddHours(-2));
        // Late, but it arrived 8 days ago — outside the window, an ordinary old message by now.
        var lateLongAgo = await InsertMessageAsync(book.Id, club.Id, other.Id, sentAt: now.AddDays(-9), receivedAt: now.AddDays(-8));

        var withLate = await LoadIdsAsync(me, book.Id, "limit=3&include_late=true");
        var plain = await LoadIdsAsync(me, book.Id, "limit=3");

        Assert.Equal([page[2].Id, page[1].Id, page[0].Id, late.Id], withLate);   // still newest-first
        // A 2.1-or-older client never asks, so it never gets a message far older than its page —
        // which would make its next "older" page (from the oldest message it holds) skip the gap.
        Assert.Equal([page[2].Id, page[1].Id, page[0].Id], plain);
        Assert.DoesNotContain(oldOnTime.Id, withLate);
        Assert.DoesNotContain(lateLongAgo.Id, withLate);
    }

    [Fact]
    public async Task A_late_arrival_already_on_the_page_is_not_returned_twice()
    {
        var (club, book, me, other) = await ArrangeAsync();
        var now = DateTime.UtcNow;
        var late = await InsertMessageAsync(book.Id, club.Id, other.Id, sentAt: now.AddMinutes(-30), receivedAt: now);
        await InsertMessageAsync(book.Id, club.Id, other.Id, sentAt: now.AddMinutes(-1));

        var ids = await LoadIdsAsync(me, book.Id, "limit=2&include_late=true");

        Assert.Equal(2, ids.Count);
        Assert.Single(ids, id => id == late.Id);
    }

    [Fact]
    public async Task Paging_older_messages_never_includes_late_arrivals()
    {
        var (club, book, me, other) = await ArrangeAsync();
        var now = DateTime.UtcNow;
        var older = await InsertMessageAsync(book.Id, club.Id, other.Id, sentAt: now.AddMinutes(-5));
        await InsertMessageAsync(book.Id, club.Id, other.Id, sentAt: now.AddHours(-3), receivedAt: now);

        var ids = await LoadIdsAsync(me, book.Id,
            $"limit=1&include_late=true&before={Uri.EscapeDataString(now.AddMinutes(-1).ToString("O"))}");

        Assert.Equal([older.Id], ids);
    }

    // ---- the dev seed for a late arrival (T5) ----------------------------------------------

    [Fact]
    public async Task The_dev_seed_sends_a_late_arrival_through_the_real_send_path()
    {
        var (_, book, me, _) = await ArrangeAsync();
        var request = new HttpRequestMessage(HttpMethod.Post, "/admin/dev/seed-late-message")
        {
            Content = JsonBody(new { book_id = book.Id, minutes_ago = 90 })
        };
        request.Headers.Add("X-Seed-Key", ApiFactory.SeedingKey);

        var dto = await ReadAsync<MessageDto>(await App.CreateClient().SendAsync(request));

        Assert.Equal("Late Larry", dto.SenderName);
        AssertClose(DateTime.UtcNow.AddMinutes(-90), dto.SentAt);
        AssertClose(DateTime.UtcNow, dto.ReceivedAt);
        Assert.Single(Hub.OfMethod("NewMessage"));        // broadcast like any send
        Assert.Equal(1, await UnreadAsync(me, book.Id));   // and new to everyone else
    }

    // ---- equal tap times (A19) ----------------------------------------------------------------

    [Fact]
    public async Task Messages_with_the_same_tap_time_always_come_back_in_the_same_order()
    {
        // Two members tapping Send in the same millisecond: the chat mustn't swap them between reads.
        var (club, book, me, other) = await ArrangeAsync();
        var tapped = DateTime.UtcNow.AddMinutes(-5);
        // Six, not two: with the tie-break removed, six rows landing in this exact order by chance
        // is 1 in 720 — so breaking it fails this test, rather than one run in two.
        var ids = new List<Guid>();
        for (var i = 0; i < 6; i++)
            ids.Add((await InsertMessageAsync(book.Id, club.Id, i % 2 == 0 ? me.Id : other.Id, sentAt: tapped)).Id);

        async Task<List<Guid>> ReadOrder() =>
            (await ReadAsync<JsonElement>(await me.Client.GetAsync($"/books/{book.Id}/messages")))
                .EnumerateArray().Select(m => m.GetProperty("id").GetGuid()).ToList();

        var first = await ReadOrder();
        Assert.Equal(6, first.Count);
        for (var i = 0; i < 5; i++) Assert.Equal(first, await ReadOrder());
        // The tie-break is the id, so every client and every page agrees.
        Assert.Equal(ids.OrderByDescending(id => (System.Data.SqlTypes.SqlGuid)id).ToList(), first);
    }
}
