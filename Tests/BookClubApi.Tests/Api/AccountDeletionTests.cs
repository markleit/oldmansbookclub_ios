using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using BookClubApi.Models;
using BookClubApi.Tests.Infrastructure;
using Microsoft.EntityFrameworkCore;

namespace BookClubApi.Tests.Api;

/// #244 (and #133) — deleting an account works for a real member, through "Delete my account" and
/// the admin's "Delete user" alike: one who has read chats, played voice messages, reacted, saved,
/// reported and been reported, blocked, asked to join, been replied to — and whose messages others'
/// read markers rest on. Before this, the self-service delete failed for everyone and the admin one
/// for nearly everyone; Apple requires in-app deletion that works.
public class AccountDeletionTests(TestAppFixture fixture) : IntegrationTestBase(fixture)
{
    private sealed record World(Club Club, Book Book, TestUser Doomed, TestUser Bystander, TestUser Admin,
        Message DoomedText, Message DoomedVoice, Message BystanderVoice, Message Reply, Message Later);

    /// A member with every kind of row there is, among people who've interacted with them.
    private async Task<World> ArrangeAsync()
    {
        var club = await CreateClubAsync();
        var other = await CreateClubAsync("Other club");
        var book = await CreateBookAsync(club.Id, "The Road");
        var doomed = await CreateUserAsync("Doomed", club.Id);
        var bystander = await CreateUserAsync("Bystander", club.Id);
        var admin = await CreateUserAsync("Admin", club.Id, isAdmin: true);
        var t0 = DateTime.UtcNow.AddMinutes(-10);

        var bystanderEarlier = await InsertMessageAsync(book.Id, club.Id, bystander.Id, sentAt: t0);
        var doomedText = await InsertMessageAsync(book.Id, club.Id, doomed.Id, sentAt: t0.AddMinutes(1));
        var doomedVoice = await InsertMessageAsync(book.Id, club.Id, doomed.Id, MessageType.Voice, sentAt: t0.AddMinutes(2));
        var bystanderVoice = await InsertMessageAsync(book.Id, club.Id, bystander.Id, MessageType.Voice, sentAt: t0.AddMinutes(3));
        var later = await InsertMessageAsync(book.Id, club.Id, doomed.Id, sentAt: t0.AddMinutes(5));
        _ = bystanderEarlier;

        Message reply;
        await using (var db = App.NewDbContext())
        {
            reply = new Message
            {
                BookId = book.Id, ClubId = club.Id, SenderId = bystander.Id, Type = MessageType.Text, Body = "replying",
                SentAt = t0.AddMinutes(4), ReceivedAt = t0.AddMinutes(4), ParentMessageId = doomedText.Id
            };
            db.Messages.Add(reply);
            db.UserDevices.Add(new UserDevice { UserId = doomed.Id, DeviceToken = "doomed-device" });
            db.RefreshTokens.Add(new RefreshToken { UserId = doomed.Id, TokenHash = new string('a', 64), ExpiresAt = DateTime.UtcNow.AddDays(90) });
            db.PendingVideos.Add(new PendingVideo
            {
                SenderId = doomed.Id, BookId = book.Id, ClientId = Guid.NewGuid(),
                MediaUrl = $"https://{FakeBlobService.Host}/club-media/{club.Id}/{Guid.NewGuid()}.mp4"
            });
            await db.SaveChangesAsync();
        }

        async Task Ok(Task<HttpResponseMessage> call, string what)
        {
            var response = await call;
            Assert.True(response.IsSuccessStatusCode, $"arranging '{what}': {(int)response.StatusCode} {await response.Content.ReadAsStringAsync()}");
        }
        // The doomed member's own trail.
        await Ok(doomed.Client.PostAsJsonAsync($"/books/{book.Id}/read", bystanderVoice.Id), "doomed reads");
        await Ok(doomed.Client.PostAsync($"/books/{book.Id}/messages/{bystanderVoice.Id}/heard", null), "doomed hears");
        await Ok(doomed.Client.PostAsJsonAsync($"/books/{book.Id}/messages/{bystanderVoice.Id}/reactions", new { emoji = "👍" }), "doomed reacts");
        await Ok(doomed.Client.PostAsync($"/messages/{bystanderVoice.Id}/save", null), "doomed saves");
        await Ok(doomed.Client.PostAsync($"/messages/{bystanderVoice.Id}/report", null), "doomed reports");
        await Ok(doomed.Client.PostAsync($"/users/{bystander.Id}/block", null), "doomed blocks");
        await Ok(doomed.Client.PostAsync($"/clubs/{other.Id}/join-request", null), "doomed asks to join");
        // Others' interactions with the doomed member's messages — and the bystander's read marker
        // resting on one of them.
        await Ok(bystander.Client.PostAsync($"/books/{book.Id}/messages/{doomedVoice.Id}/heard", null), "bystander hears");
        await Ok(bystander.Client.PostAsJsonAsync($"/books/{book.Id}/messages/{doomedVoice.Id}/reactions", new { emoji = "😂" }), "bystander reacts");
        await Ok(bystander.Client.PostAsync($"/messages/{doomedText.Id}/save", null), "bystander saves");
        await Ok(bystander.Client.PostAsync($"/messages/{doomedText.Id}/report", null), "bystander reports");
        await Ok(bystander.Client.PostAsync($"/users/{doomed.Id}/block", null), "bystander blocks");
        await Ok(bystander.Client.PostAsJsonAsync($"/books/{book.Id}/read", doomedVoice.Id), "bystander reads");

        return new World(club, book, doomed, bystander, admin, doomedText, doomedVoice, bystanderVoice, reply, later);
    }

    private async Task<int> UnreadAsync(TestUser user, Guid bookId)
    {
        var body = await ReadAsync<JsonElement>(await user.Client.GetAsync("/books"));
        return body.EnumerateArray().Single(b => b.GetProperty("id").GetGuid() == bookId).GetProperty("unread_count").GetInt32();
    }

    private async Task AssertEverythingOfTheirsIsGoneAndOthersAreIntactAsync(World w, int bystanderUnreadBefore)
    {
        await using var db = App.NewDbContext();
        var id = w.Doomed.Id;
        Assert.Null(await db.Users.FindAsync(id));
        Assert.False(await db.Messages.AnyAsync(m => m.SenderId == id));
        Assert.False(await db.Memberships.AnyAsync(m => m.UserId == id));
        Assert.False(await db.UserDevices.AnyAsync(d => d.UserId == id));
        Assert.False(await db.RefreshTokens.AnyAsync(t => t.UserId == id));
        Assert.False(await db.PendingVideos.AnyAsync(p => p.SenderId == id));
        Assert.False(await db.ChatReads.AnyAsync(c => c.UserId == id));
        Assert.False(await db.MessageHeards.AnyAsync(h => h.UserId == id || h.MessageId == w.DoomedVoice.Id));
        Assert.False(await db.MessageReactions.AnyAsync(r => r.UserId == id || r.MessageId == w.DoomedVoice.Id));
        Assert.False(await db.SavedMessages.AnyAsync(s => s.UserId == id || s.MessageId == w.DoomedText.Id));
        Assert.False(await db.Reports.AnyAsync(r => r.ReporterId == id || r.MessageId == w.DoomedText.Id));
        Assert.False(await db.BlockedUsers.AnyAsync(b => b.BlockerId == id || b.BlockedId == id));
        Assert.False(await db.JoinRequests.AnyAsync(j => j.UserId == id));

        // Everyone else's: the reply keeps its words and loses only the quote of what's gone…
        var reply = await db.Messages.SingleAsync(m => m.Id == w.Reply.Id);
        Assert.Equal("replying", reply.Body);
        Assert.Null(reply.ParentMessageId);
        Assert.NotNull(await db.Messages.FindAsync(w.BystanderVoice.Id));
        // …and their read marker moved back to the last thing left before it, so their chat
        // doesn't suddenly count as all unread (it rested on one of the deleted messages).
        var marker = await db.ChatReads.SingleAsync(c => c.UserId == w.Bystander.Id && c.BookId == w.Book.Id);
        Assert.NotNull(marker.LastSeenMessageId);
        Assert.True(await db.Messages.AnyAsync(m => m.Id == marker.LastSeenMessageId), "the marker points at a message that exists");
        Assert.Equal(bystanderUnreadBefore, await UnreadAsync(w.Bystander, w.Book.Id));
    }

    [Fact]
    public async Task A_member_can_delete_their_own_account_whatever_they_have_done()
    {
        var w = await ArrangeAsync();
        var unreadBefore = await UnreadAsync(w.Bystander, w.Book.Id);

        var response = await w.Doomed.Client.DeleteAsync("/auth/me");

        Assert.True(response.StatusCode == HttpStatusCode.NoContent, await response.Content.ReadAsStringAsync());
        await AssertEverythingOfTheirsIsGoneAndOthersAreIntactAsync(w, unreadBefore);
    }

    [Fact]
    public async Task An_admin_can_delete_a_member_whatever_they_have_done()
    {
        var w = await ArrangeAsync();
        var unreadBefore = await UnreadAsync(w.Bystander, w.Book.Id);

        var response = await w.Admin.Client.DeleteAsync($"/admin/users/{w.Doomed.Id}");

        Assert.True(response.StatusCode == HttpStatusCode.NoContent, await response.Content.ReadAsStringAsync());
        await AssertEverythingOfTheirsIsGoneAndOthersAreIntactAsync(w, unreadBefore);
    }

    [Fact]
    public async Task K5_deleting_the_account_ends_the_send_token()
    {
        // docs/SEND_REQUIREMENTS.md K5: a real sign-in's send token stops working with the account.
        var signIn = await App.CreateClient().PostAsync("/auth/apple", JsonBody(new
        {
            identity_token = "any-token-the-validator-is-faked", display_name = "Mark", club_name = "Club"
        }));
        var body = await ReadAsync<JsonElement>(signIn);
        Guid bookId;
        await using (var db = App.NewDbContext()) bookId = (await CreateBookAsync((await db.Clubs.SingleAsync()).Id, "The Road")).Id;
        var access = App.CreateClient();
        access.DefaultRequestHeaders.Authorization = new("Bearer", body.GetProperty("access_token").GetString());
        var send = App.CreateClient();
        send.DefaultRequestHeaders.Authorization = new("Bearer", body.GetProperty("send_token").GetString());

        Assert.Equal(HttpStatusCode.NoContent, (await access.DeleteAsync("/auth/me")).StatusCode);

        var after = await send.PostAsync($"/books/{bookId}/messages", JsonBody(new { type = "Text", body = "hello", client_id = Guid.NewGuid() }));
        Assert.Equal(HttpStatusCode.Unauthorized, after.StatusCode);
    }
}
