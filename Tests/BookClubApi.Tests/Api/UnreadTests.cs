using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using BookClubApi.Models;
using BookClubApi.Tests.Infrastructure;
using Microsoft.EntityFrameworkCore;

namespace BookClubApi.Tests.Api;

/// The unread count and the read/heard state that feeds it.
///
/// This number is not cosmetic: the client applies whatever the server returns verbatim
/// (APIClient.unreadCount), and the same calculator drives the app icon badge via the push
/// fan-out. A wrong value here shows up as a badge that won't clear — the single most-reported
/// class of bug in this app's history (#102, #107, #108, #119).
public class UnreadTests(TestAppFixture fixture) : IntegrationTestBase(fixture)
{
    private async Task<(Club Club, Book Book, TestUser Me, TestUser Other)> ArrangeAsync()
    {
        var club = await CreateClubAsync();
        var book = await CreateBookAsync(club.Id, "The Road");
        var me = await CreateUserAsync("Me", club.Id);
        var other = await CreateUserAsync("Other", club.Id);
        return (club, book, me, other);
    }

    private static async Task<int> UnreadFrom(HttpResponseMessage response)
    {
        var body = await response.Content.ReadAsStringAsync();
        Assert.True(response.IsSuccessStatusCode, $"{(int)response.StatusCode}: {body}");
        // snake_case on the wire: the server declares `new { unreadCount = ... }` but the
        // SnakeCaseLower policy rewrites it, which is what the iOS client's
        // .convertFromSnakeCase decoder expects. Asserting the wire name here is deliberate —
        // it is half of the client contract.
        return JsonDocument.Parse(body).RootElement.GetProperty("unread_count").GetInt32();
    }

    /// The books list carries the same count under a different shape; both must agree, since one
    /// paints the library row and the other paints the chat screen.
    private async Task<int> UnreadFromBooksList(TestUser user, Guid bookId)
    {
        var response = await user.Client.GetAsync("/books");
        var body = await response.Content.ReadAsStringAsync();
        Assert.True(response.IsSuccessStatusCode, body);
        foreach (var book in JsonDocument.Parse(body).RootElement.EnumerateArray())
            if (book.GetProperty("id").GetGuid() == bookId)
                return book.GetProperty("unread_count").GetInt32();
        throw new InvalidOperationException($"Book {bookId} not in the books list.");
    }

    // ---- the formula ------------------------------------------------------------------------

    [Fact]
    public async Task Your_own_messages_are_never_unread()
    {
        var (club, book, me, _) = await ArrangeAsync();
        await InsertMessageAsync(book.Id, club.Id, me.Id);
        await InsertMessageAsync(book.Id, club.Id, me.Id);

        Assert.Equal(0, await UnreadFromBooksList(me, book.Id));
    }

    [Fact]
    public async Task Others_text_messages_after_the_read_marker_are_unread()
    {
        var (club, book, me, other) = await ArrangeAsync();
        await InsertMessageAsync(book.Id, club.Id, other.Id);
        await InsertMessageAsync(book.Id, club.Id, other.Id);

        Assert.Equal(2, await UnreadFromBooksList(me, book.Id));
    }

    [Fact]
    public async Task Deleted_messages_do_not_count()
    {
        var (club, book, me, other) = await ArrangeAsync();
        await InsertMessageAsync(book.Id, club.Id, other.Id);
        await InsertMessageAsync(book.Id, club.Id, other.Id, deletedAt: DateTime.UtcNow);

        Assert.Equal(1, await UnreadFromBooksList(me, book.Id));
    }

    [Fact]
    public async Task Messages_from_a_blocked_sender_do_not_count()
    {
        var (club, book, me, other) = await ArrangeAsync();
        await InsertMessageAsync(book.Id, club.Id, other.Id);

        var blocked = await me.Client.PostAsync($"/users/{other.Id}/block", null);
        Assert.True(blocked.IsSuccessStatusCode, await blocked.Content.ReadAsStringAsync());

        Assert.Equal(0, await UnreadFromBooksList(me, book.Id));
    }

    [Fact]
    public async Task A_voice_message_stays_unread_after_the_read_marker_passes_it()
    {
        // The subtlest rule in the calculator, and the one a "simplification" would erase: voice
        // is unread until HEARD, independent of the last-seen marker. Scrolling past a voice
        // message is not the same as listening to it, and the badge has to reflect that.
        var (club, book, me, other) = await ArrangeAsync();
        var voice = await InsertMessageAsync(book.Id, club.Id, other.Id, MessageType.Voice);
        var later = await InsertMessageAsync(book.Id, club.Id, other.Id, sentAt: voice.SentAt.AddSeconds(10));

        var afterRead = await me.Client.PostAsJsonAsync($"/books/{book.Id}/read", later.Id);

        // Text is now read; the voice message is not, because it was never heard.
        Assert.Equal(1, await UnreadFrom(afterRead));

        var afterHeard = await me.Client.PostAsync($"/books/{book.Id}/messages/{voice.Id}/heard", null);
        Assert.Equal(0, await UnreadFrom(afterHeard));
    }

    [Fact]
    public async Task The_badge_total_equals_the_sum_of_the_per_book_counts()
    {
        // The push fan-out sets the icon badge from the total while the client paints each row
        // from the per-book number. If those two ever disagree the badge cannot be cleared by
        // reading anything, which is exactly what #119 was.
        var club = await CreateClubAsync();
        var one = await CreateBookAsync(club.Id, "Book One");
        var two = await CreateBookAsync(club.Id, "Book Two");
        var me = await CreateUserAsync("Me", club.Id);
        var other = await CreateUserAsync("Other", club.Id);

        await InsertMessageAsync(one.Id, club.Id, other.Id);
        await InsertMessageAsync(two.Id, club.Id, other.Id);
        await InsertMessageAsync(two.Id, club.Id, other.Id);

        await using var db = App.NewDbContext();
        var (total, perBook) = await BookClubApi.Services.UnreadCalculator.TotalWithPerBookAsync(db, me.Id);

        Assert.Equal(3, total);
        Assert.Equal(perBook.Values.Sum(), total);
        Assert.Equal(1, perBook[one.Id]);
        Assert.Equal(2, perBook[two.Id]);
    }

    // ---- read frontier ----------------------------------------------------------------------

    [Fact]
    public async Task The_read_marker_only_ever_advances()
    {
        var (club, book, me, other) = await ArrangeAsync();
        var first = await InsertMessageAsync(book.Id, club.Id, other.Id, body: "first");
        var second = await InsertMessageAsync(book.Id, club.Id, other.Id, body: "second", sentAt: first.SentAt.AddSeconds(10));

        await me.Client.PostAsJsonAsync($"/books/{book.Id}/read", second.Id);
        Hub.Clear();

        // A client working from a stale cache re-marks the OLDER message. Accepting it would
        // rewind the frontier and resurrect an already-read message as unread.
        var rewind = await me.Client.PostAsJsonAsync($"/books/{book.Id}/read", first.Id);

        Assert.Equal(0, await UnreadFrom(rewind));
        await using var db = App.NewDbContext();
        var marker = await db.ChatReads.SingleAsync(cr => cr.UserId == me.Id && cr.BookId == book.Id);
        Assert.Equal(second.Id, marker.LastSeenMessageId);

        // And no receipt goes out — nothing changed, so telling everyone it did would be a lie
        // that other clients would render as a moved read indicator.
        Assert.Empty(Hub.Sends);
    }

    [Fact]
    public async Task Marking_an_unknown_message_is_ignored_but_still_returns_the_count()
    {
        var (club, book, me, other) = await ArrangeAsync();
        await InsertMessageAsync(book.Id, club.Id, other.Id);

        var response = await me.Client.PostAsJsonAsync($"/books/{book.Id}/read", Guid.NewGuid());

        Assert.Equal(1, await UnreadFrom(response));
        await using var db = App.NewDbContext();
        Assert.False(await db.ChatReads.AnyAsync(cr => cr.UserId == me.Id));
    }

    // ---- heard batch ------------------------------------------------------------------------

    [Fact]
    public async Task Heard_batch_accepts_only_others_live_voice_messages_in_this_book()
    {
        var (club, book, me, other) = await ArrangeAsync();
        var otherBook = await CreateBookAsync(club.Id, "Elsewhere");

        var acceptable = await InsertMessageAsync(book.Id, club.Id, other.Id, MessageType.Voice);
        var mine = await InsertMessageAsync(book.Id, club.Id, me.Id, MessageType.Voice);
        var deleted = await InsertMessageAsync(book.Id, club.Id, other.Id, MessageType.Voice, deletedAt: DateTime.UtcNow);
        var elsewhere = await InsertMessageAsync(otherBook.Id, club.Id, other.Id, MessageType.Voice);
        var text = await InsertMessageAsync(book.Id, club.Id, other.Id);
        var unknown = Guid.NewGuid();

        var response = await me.Client.PostAsJsonAsync($"/books/{book.Id}/heard",
            new[] { acceptable.Id, mine.Id, deleted.Id, elsewhere.Id, text.Id, unknown });

        var body = await response.Content.ReadAsStringAsync();
        Assert.True(response.IsSuccessStatusCode, body);
        var heard = JsonDocument.Parse(body).RootElement.GetProperty("heard")
            .EnumerateArray().Select(e => e.GetGuid()).ToHashSet();

        // The client permanently ABANDONS every id it asked about that isn't echoed back
        // (HeardStore.abandon), so this set being too narrow silently discards real user marks,
        // and too broad accepts state that will never be consistent.
        Assert.Equal([acceptable.Id], heard);
    }

    [Fact]
    public async Task Replaying_an_already_applied_heard_batch_still_confirms()
    {
        var (club, book, me, other) = await ArrangeAsync();
        var voice = await InsertMessageAsync(book.Id, club.Id, other.Id, MessageType.Voice);

        await me.Client.PostAsJsonAsync($"/books/{book.Id}/heard", new[] { voice.Id });
        var replay = await me.Client.PostAsJsonAsync($"/books/{book.Id}/heard", new[] { voice.Id });

        var body = await replay.Content.ReadAsStringAsync();
        var heard = JsonDocument.Parse(body).RootElement.GetProperty("heard")
            .EnumerateArray().Select(e => e.GetGuid()).ToList();

        // `heard` echoes everything acceptable, not just rows written this time. If it echoed
        // only new writes, a retry would look like a refusal and the client would abandon an id
        // it had legitimately marked.
        Assert.Equal([voice.Id], heard);
    }

    [Fact]
    public async Task An_empty_heard_batch_is_a_no_op_that_still_reports_the_count()
    {
        var (club, book, me, other) = await ArrangeAsync();
        await InsertMessageAsync(book.Id, club.Id, other.Id);

        var response = await me.Client.PostAsJsonAsync($"/books/{book.Id}/heard", Array.Empty<Guid>());

        Assert.Equal(1, await UnreadFrom(response));
    }

    [Fact]
    public async Task Mark_all_heard_clears_only_others_voice_messages()
    {
        var (club, book, me, other) = await ArrangeAsync();
        await InsertMessageAsync(book.Id, club.Id, other.Id, MessageType.Voice);
        await InsertMessageAsync(book.Id, club.Id, other.Id, MessageType.Voice);
        await InsertMessageAsync(book.Id, club.Id, me.Id, MessageType.Voice);
        var text = await InsertMessageAsync(book.Id, club.Id, other.Id);

        var response = await me.Client.PostAsync($"/books/{book.Id}/heard/all", null);

        // The two voice messages are heard; the unread text message is untouched, because
        // "mark all as heard" is not "mark all as read".
        Assert.Equal(1, await UnreadFrom(response));

        await using var db = App.NewDbContext();
        Assert.Equal(2, await db.MessageHeards.CountAsync(h => h.UserId == me.Id));
        Assert.False(await db.MessageHeards.AnyAsync(h => h.UserId == me.Id && h.MessageId == text.Id));
    }

    [Fact]
    public async Task Heard_state_is_sticky_and_idempotent()
    {
        var (club, book, me, other) = await ArrangeAsync();
        var voice = await InsertMessageAsync(book.Id, club.Id, other.Id, MessageType.Voice);

        await me.Client.PostAsync($"/books/{book.Id}/messages/{voice.Id}/heard", null);
        await me.Client.PostAsync($"/books/{book.Id}/messages/{voice.Id}/heard", null);

        await using var db = App.NewDbContext();
        Assert.Equal(1, await db.MessageHeards.CountAsync(h => h.UserId == me.Id && h.MessageId == voice.Id));
    }

    [Fact]
    public async Task My_heard_returns_the_callers_own_heard_ids()
    {
        var (club, book, me, other) = await ArrangeAsync();
        var heardByMe = await InsertMessageAsync(book.Id, club.Id, other.Id, MessageType.Voice);
        await InsertMessageAsync(book.Id, club.Id, other.Id, MessageType.Voice);

        await me.Client.PostAsync($"/books/{book.Id}/messages/{heardByMe.Id}/heard", null);
        var mine = await ReadAsync<List<Guid>>(await me.Client.GetAsync($"/books/{book.Id}/my-heard"));
        var theirs = await ReadAsync<List<Guid>>(await other.Client.GetAsync($"/books/{book.Id}/my-heard"));

        Assert.Equal([heardByMe.Id], mine);
        Assert.Empty(theirs);   // heard state is per-account, not global (#102)
    }

    // ---- authorization ----------------------------------------------------------------------

    [Fact]
    public async Task A_non_member_cannot_read_or_mark_anything_in_the_book()
    {
        var (club, book, _, other) = await ArrangeAsync();
        var message = await InsertMessageAsync(book.Id, club.Id, other.Id, MessageType.Voice);
        var outsider = await CreateUserAsync("Outsider");

        foreach (var response in new[]
        {
            await outsider.Client.PostAsJsonAsync($"/books/{book.Id}/read", message.Id),
            await outsider.Client.PostAsync($"/books/{book.Id}/heard/all", null),
            await outsider.Client.PostAsync($"/books/{book.Id}/messages/{message.Id}/heard", null),
            await outsider.Client.PostAsJsonAsync($"/books/{book.Id}/heard", new[] { message.Id }),
            await outsider.Client.GetAsync($"/books/{book.Id}/my-heard"),
        })
        {
            Assert.Equal(HttpStatusCode.Forbidden, response.StatusCode);
        }
    }
}
