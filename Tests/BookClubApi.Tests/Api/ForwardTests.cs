using System.Net;
using BookClubApi.Models;
using BookClubApi.Tests.Infrastructure;
using Microsoft.EntityFrameworkCore;

namespace BookClubApi.Tests.Api;

/// #204 — forwarding a saved message over the REST send (forward_message_id + client_id). It was
/// the last send left on the SignalR hub, which needs a live connection and carries no client id,
/// so a retried forward could post twice. The hub method stays for 2.1-and-older clients.
public class ForwardTests(TestAppFixture fixture) : IntegrationTestBase(fixture)
{
    private async Task<(Book From, Book To, TestUser Member, Message Original)> ArrangeAsync()
    {
        var club = await CreateClubAsync();
        var from = await CreateBookAsync(club.Id, "The Road");
        var to = await CreateBookAsync(club.Id, "Blood Meridian");
        var member = await CreateUserAsync("Mark", club.Id);
        var author = await CreateUserAsync("Dixie", club.Id);
        var original = await InsertMessageAsync(from.Id, club.Id, author.Id, MessageType.Voice);
        await SaveAsync(member.Id, original.Id);
        return (from, to, member, original);
    }

    private async Task SaveAsync(Guid userId, Guid messageId)
    {
        await using var db = App.NewDbContext();
        db.SavedMessages.Add(new SavedMessage { UserId = userId, MessageId = messageId });
        await db.SaveChangesAsync();
    }

    private static object Forward(Guid messageId, Guid clientId) => new
    {
        type = "Text",   // ignored for a forward — the original's type is used
        client_id = clientId,
        forward_message_id = messageId
    };

    [Fact]
    public async Task A_forward_posts_a_forwarded_copy_of_the_original()
    {
        var (_, to, member, original) = await ArrangeAsync();

        var dto = await ReadAsync<MessageDto>(
            await member.Client.PostAsync($"/books/{to.Id}/messages", JsonBody(Forward(original.Id, Guid.NewGuid()))));

        Assert.True(dto.IsForwarded);
        Assert.Equal(MessageType.Voice, dto.Type);
        Assert.Equal(member.Id, dto.SenderId);
        Assert.Contains("?sig=", dto.MediaUrl);
        await using var db = App.NewDbContext();
        var copy = await db.Messages.SingleAsync(m => m.BookId == to.Id);
        Assert.Equal(original.MediaUrl, copy.MediaUrl);   // stored plain, like the original
        Assert.Single(DrainPushes());
    }

    [Fact]
    public async Task Retrying_a_forward_with_the_same_client_id_posts_it_once()
    {
        var (_, to, member, original) = await ArrangeAsync();
        var clientId = Guid.NewGuid();

        var first = await ReadAsync<MessageDto>(
            await member.Client.PostAsync($"/books/{to.Id}/messages", JsonBody(Forward(original.Id, clientId))));
        var second = await ReadAsync<MessageDto>(
            await member.Client.PostAsync($"/books/{to.Id}/messages", JsonBody(Forward(original.Id, clientId))));

        Assert.Equal(first.Id, second.Id);
        await using var db = App.NewDbContext();
        Assert.Equal(1, await db.Messages.CountAsync(m => m.BookId == to.Id));
        Assert.Single(DrainPushes());
    }

    [Fact]
    public async Task Forwarding_a_message_you_have_not_saved_is_refused()
    {
        var (from, to, member, _) = await ArrangeAsync();
        var unsaved = await InsertMessageAsync(from.Id, from.ClubId, member.Id);

        var response = await member.Client.PostAsync($"/books/{to.Id}/messages", JsonBody(Forward(unsaved.Id, Guid.NewGuid())));

        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
        Assert.Contains("saved", await response.Content.ReadAsStringAsync());
    }

    [Fact]
    public async Task Forwarding_a_deleted_message_is_refused()
    {
        var (_, to, member, original) = await ArrangeAsync();
        await using (var db = App.NewDbContext())
        {
            (await db.Messages.SingleAsync(m => m.Id == original.Id)).DeletedAt = DateTime.UtcNow;
            await db.SaveChangesAsync();
        }

        var response = await member.Client.PostAsync($"/books/{to.Id}/messages", JsonBody(Forward(original.Id, Guid.NewGuid())));

        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
        Assert.Contains("deleted", await response.Content.ReadAsStringAsync());
    }

    [Fact]
    public async Task Forwarding_into_a_club_you_are_not_in_is_refused()
    {
        var (_, _, member, original) = await ArrangeAsync();
        var otherClub = await CreateClubAsync("Other Club");
        var elsewhere = await CreateBookAsync(otherClub.Id, "Elsewhere");

        var response = await member.Client.PostAsync($"/books/{elsewhere.Id}/messages", JsonBody(Forward(original.Id, Guid.NewGuid())));

        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
        await using var db = App.NewDbContext();
        Assert.Equal(0, await db.Messages.CountAsync(m => m.BookId == elsewhere.Id));
    }
}
