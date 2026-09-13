using System.Globalization;
using System.Net;
using System.Net.Http.Json;
using BookClubApi.Models;
using BookClubApi.Tests.Infrastructure;
using Microsoft.EntityFrameworkCore;

namespace BookClubApi.Tests.Api;

/// Reading messages back: pagination, the deleted-message tombstone shape, reply previews and
/// reactions.
public class MessagesTests(TestAppFixture fixture) : IntegrationTestBase(fixture)
{
    private async Task<(Club Club, Book Book, TestUser Me, TestUser Other)> ArrangeAsync()
    {
        var club = await CreateClubAsync();
        var book = await CreateBookAsync(club.Id, "The Road");
        var me = await CreateUserAsync("Me", club.Id);
        var other = await CreateUserAsync("Other", club.Id);
        return (club, book, me, other);
    }

    /// Matches how the iOS client formats the cursor (ISO-8601 with fractional seconds). Dropping
    /// the milliseconds here is not cosmetic — it would silently skip every message sent in the
    /// same second as the cursor.
    private static string Cursor(DateTime sentAt) =>
        sentAt.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffffffZ", CultureInfo.InvariantCulture);

    [Fact]
    public async Task Messages_come_back_newest_first()
    {
        var (club, book, me, other) = await ArrangeAsync();
        var start = DateTime.UtcNow.AddMinutes(-10);
        for (var i = 0; i < 3; i++)
            await InsertMessageAsync(book.Id, club.Id, other.Id, body: $"msg {i}", sentAt: start.AddMinutes(i));

        var messages = await ReadAsync<List<MessageDto>>(await me.Client.GetAsync($"/books/{book.Id}/messages"));

        Assert.Equal(["msg 2", "msg 1", "msg 0"], messages.Select(m => m.Body));
    }

    [Fact]
    public async Task The_before_cursor_is_strictly_exclusive()
    {
        var (club, book, me, other) = await ArrangeAsync();
        var start = DateTime.UtcNow.AddMinutes(-10);
        var first = await InsertMessageAsync(book.Id, club.Id, other.Id, body: "first", sentAt: start);
        var second = await InsertMessageAsync(book.Id, club.Id, other.Id, body: "second", sentAt: start.AddMinutes(1));
        await InsertMessageAsync(book.Id, club.Id, other.Id, body: "third", sentAt: start.AddMinutes(2));

        var page = await ReadAsync<List<MessageDto>>(
            await me.Client.GetAsync($"/books/{book.Id}/messages?before={Cursor(second.SentAt)}"));

        // Strictly earlier than the cursor: the cursor message itself is the last one the client
        // already has, so returning it again would duplicate a bubble on every page turn.
        Assert.Equal(["first"], page.Select(m => m.Body));
        Assert.DoesNotContain(page, m => m.Id == second.Id);
        Assert.Contains(page, m => m.Id == first.Id);
    }

    [Fact]
    public async Task Limit_caps_the_page_size()
    {
        var (club, book, me, other) = await ArrangeAsync();
        var start = DateTime.UtcNow.AddMinutes(-10);
        for (var i = 0; i < 5; i++)
            await InsertMessageAsync(book.Id, club.Id, other.Id, body: $"msg {i}", sentAt: start.AddMinutes(i));

        var page = await ReadAsync<List<MessageDto>>(await me.Client.GetAsync($"/books/{book.Id}/messages?limit=2"));

        Assert.Equal(["msg 4", "msg 3"], page.Select(m => m.Body));
    }

    [Fact]
    public async Task A_deleted_message_comes_back_as_a_tombstone_with_its_content_stripped()
    {
        var (club, book, me, other) = await ArrangeAsync();
        await InsertMessageAsync(book.Id, club.Id, other.Id, MessageType.Voice,
            body: "secret", deletedAt: DateTime.UtcNow, clientId: Guid.NewGuid());

        var messages = await ReadAsync<List<MessageDto>>(await me.Client.GetAsync($"/books/{book.Id}/messages"));

        // The row is still returned — clients need the tombstone to replace an existing bubble
        // rather than leaving stale content on screen — but every field that could leak the
        // deleted content or its author must be blank.
        var tombstone = Assert.Single(messages);
        Assert.True(tombstone.IsDeleted);
        Assert.Equal(Guid.Empty, tombstone.SenderId);
        Assert.Equal("", tombstone.SenderName);
        Assert.Null(tombstone.Body);
        Assert.Null(tombstone.MediaUrl);
        Assert.Null(tombstone.DurationSeconds);
        Assert.Null(tombstone.ClientId);
        Assert.NotEqual(default, tombstone.SentAt);   // kept, so it still sorts into place
    }

    [Fact]
    public async Task A_non_member_cannot_read_a_books_messages()
    {
        var (_, book, _, _) = await ArrangeAsync();
        var outsider = await CreateUserAsync("Outsider");

        var response = await outsider.Client.GetAsync($"/books/{book.Id}/messages");

        Assert.Equal(HttpStatusCode.Forbidden, response.StatusCode);
    }

    [Fact]
    public async Task An_unknown_book_is_a_404_not_a_403()
    {
        var (_, _, me, _) = await ArrangeAsync();

        var response = await me.Client.GetAsync($"/books/{Guid.NewGuid()}/messages");

        Assert.Equal(HttpStatusCode.NotFound, response.StatusCode);
    }

    // ---- reactions --------------------------------------------------------------------------

    [Fact]
    public async Task A_user_has_at_most_one_reaction_per_message_and_switching_replaces_it()
    {
        var (club, book, me, other) = await ArrangeAsync();
        var message = await InsertMessageAsync(book.Id, club.Id, other.Id);

        await me.Client.PostAsJsonAsync($"/books/{book.Id}/messages/{message.Id}/reactions", new { emoji = "👍" });
        await me.Client.PostAsJsonAsync($"/books/{book.Id}/messages/{message.Id}/reactions", new { emoji = "🔥" });

        await using var db = App.NewDbContext();
        var reaction = Assert.Single(await db.MessageReactions.Where(r => r.MessageId == message.Id).ToListAsync());
        Assert.Equal("🔥", reaction.Emoji);
    }

    [Fact]
    public async Task Removing_a_reaction_is_idempotent_and_only_broadcasts_when_something_changed()
    {
        var (club, book, me, other) = await ArrangeAsync();
        var message = await InsertMessageAsync(book.Id, club.Id, other.Id);
        await me.Client.PostAsJsonAsync($"/books/{book.Id}/messages/{message.Id}/reactions", new { emoji = "👍" });
        Hub.Clear();

        var first = await me.Client.DeleteAsync($"/books/{book.Id}/messages/{message.Id}/reactions");
        var second = await me.Client.DeleteAsync($"/books/{book.Id}/messages/{message.Id}/reactions");

        Assert.Equal(HttpStatusCode.NoContent, first.StatusCode);
        Assert.Equal(HttpStatusCode.NoContent, second.StatusCode);

        // Exactly one receipt: the second delete removed nothing, and announcing a change that
        // did not happen makes every other client redraw a reaction bar for no reason.
        Assert.Single(Hub.OfMethod("ReactionReceipt"));
    }

    [Theory]
    [InlineData("")]
    [InlineData("   ")]
    [InlineData("this string is far too long to be an emoji")]
    public async Task An_invalid_emoji_is_refused(string emoji)
    {
        var (club, book, me, other) = await ArrangeAsync();
        var message = await InsertMessageAsync(book.Id, club.Id, other.Id);

        var response = await me.Client.PostAsJsonAsync($"/books/{book.Id}/messages/{message.Id}/reactions", new { emoji });

        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
    }

    [Fact]
    public async Task You_cannot_react_to_a_deleted_message()
    {
        var (club, book, me, other) = await ArrangeAsync();
        var message = await InsertMessageAsync(book.Id, club.Id, other.Id, deletedAt: DateTime.UtcNow);

        var response = await me.Client.PostAsJsonAsync($"/books/{book.Id}/messages/{message.Id}/reactions", new { emoji = "👍" });

        Assert.Equal(HttpStatusCode.NotFound, response.StatusCode);
    }

    [Fact]
    public async Task Reactors_come_back_in_the_order_they_reacted()
    {
        var (club, book, me, other) = await ArrangeAsync();
        var third = await CreateUserAsync("Third", club.Id);
        var message = await InsertMessageAsync(book.Id, club.Id, other.Id);

        await other.Client.PostAsJsonAsync($"/books/{book.Id}/messages/{message.Id}/reactions", new { emoji = "👍" });
        await me.Client.PostAsJsonAsync($"/books/{book.Id}/messages/{message.Id}/reactions", new { emoji = "🔥" });
        await third.Client.PostAsJsonAsync($"/books/{book.Id}/messages/{message.Id}/reactions", new { emoji = "😂" });

        var reactors = await ReadAsync<List<ReactionReactorDto>>(
            await me.Client.GetAsync($"/books/{book.Id}/messages/{message.Id}/reactions"));

        Assert.Equal(["Other", "Me", "Third"], reactors.Select(r => r.DisplayName));
    }

    // ---- saved messages ---------------------------------------------------------------------

    [Fact]
    public async Task Saving_is_idempotent_and_unsaving_is_safe_when_nothing_was_saved()
    {
        var (club, book, me, other) = await ArrangeAsync();
        var message = await InsertMessageAsync(book.Id, club.Id, other.Id);

        await me.Client.PostAsync($"/messages/{message.Id}/save", null);
        await me.Client.PostAsync($"/messages/{message.Id}/save", null);
        await using (var db = App.NewDbContext())
            Assert.Equal(1, await db.SavedMessages.CountAsync(s => s.UserId == me.Id));

        var first = await me.Client.DeleteAsync($"/messages/{message.Id}/save");
        var second = await me.Client.DeleteAsync($"/messages/{message.Id}/save");
        Assert.Equal(HttpStatusCode.NoContent, first.StatusCode);
        Assert.Equal(HttpStatusCode.NoContent, second.StatusCode);
    }

    [Fact]
    public async Task A_transcript_is_written_once_and_never_overwritten()
    {
        var (club, book, me, other) = await ArrangeAsync();
        var voice = await InsertMessageAsync(book.Id, club.Id, other.Id, MessageType.Voice);

        await me.Client.PostAsJsonAsync($"/messages/{voice.Id}/transcript", new { transcript = "the first transcription" });
        await me.Client.PostAsJsonAsync($"/messages/{voice.Id}/transcript", new { transcript = "a second device disagrees" });

        // Set-once: two devices transcribing the same clip locally will disagree, and the text is
        // quoted in replies for everyone, so it must not flip depending on who posted last.
        await using var db = App.NewDbContext();
        Assert.Equal("the first transcription", (await db.Messages.FindAsync(voice.Id))!.Transcript);
    }

    [Fact]
    public async Task Reporting_the_same_message_twice_files_one_report()
    {
        var (club, book, me, other) = await ArrangeAsync();
        var message = await InsertMessageAsync(book.Id, club.Id, other.Id);

        await me.Client.PostAsync($"/messages/{message.Id}/report", null);
        await me.Client.PostAsync($"/messages/{message.Id}/report", null);

        await using var db = App.NewDbContext();
        Assert.Equal(1, await db.Reports.CountAsync(r => r.ReporterId == me.Id && r.MessageId == message.Id));
    }
}
