using BookClubApi.Data;
using BookClubApi.Models;
using BookClubApi.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.SignalR;
using Microsoft.EntityFrameworkCore;

namespace BookClubApi.Hubs;

[Authorize]
public class ChatHub(AppDbContext db, MessageSendService messageSend) : Hub
{
    public async Task JoinBook(Guid bookId)
    {
        var book = await db.Books.FindAsync(bookId);
        if (book is null) return;

        var conn = await GetConnUserAsync();
        if (!conn.ClubIds.Contains(book.ClubId)) return;

        await Groups.AddToGroupAsync(Context.ConnectionId, bookId.ToString());
    }

    // Lightweight "is typing / recording" ping. Throttled client-side; broadcast to
    // others in the book group (not persisted, no notification). The client auto-clears
    // the indicator on a timeout, so a dropped event can't leave it stuck.
    public async Task Typing(Guid bookId, bool isRecording)
    {
        var userId = GetUserId();
        var u = await db.Users.Where(x => x.Id == userId)
            .Select(x => new { x.Nickname, x.DisplayName }).FirstOrDefaultAsync();
        if (u is null) return;
        // Use the full Nickname when set (a nickname isn't "first last", so don't chop
        // it); otherwise trim a real DisplayName to its first name.
        var name = !string.IsNullOrWhiteSpace(u.Nickname)
            ? u.Nickname
            : (u.DisplayName.Split(' ', StringSplitOptions.RemoveEmptyEntries).FirstOrDefault() ?? u.DisplayName);
        await Clients.OthersInGroup(bookId.ToString())
            .SendAsync("UserTyping", new { bookId, userId, displayName = name, isRecording });
    }

    // NOTE: SignalR matches hub methods by EXACT argument count (it does NOT apply C#
    // default values). So the parameter count of each public method is part of its wire
    // contract — adding a param breaks older clients. SendTextMessage MUST stay at its
    // original 1.5.0 arity (bookId, body) forever: the live App Store client invokes it
    // with exactly 2 args. clientId (dedup) and replies go through SEPARATE method names.
    // (A "default" param here doesn't help — SignalR still requires that arg count.)
    //
    // The actual save+broadcast logic lives in MessageSendService, shared with the REST
    // POST /books/{bookId}/messages endpoint (MessagesController) — that endpoint is what
    // the client now uses for a send that has to survive being backgrounded, since it can
    // run over a background URLSession with no time limit, unlike a SignalR invoke which
    // needs a live WebSocket. These hub methods stay for older installed clients and for
    // the live foreground path.
    public Task SendTextMessage(Guid bookId, string body)
        => SendTextCore(bookId, body, null, null);
    public Task SendTextWithClientId(Guid bookId, string body, Guid clientId)
        => SendTextCore(bookId, body, clientId, null);
    public Task SendTextReply(Guid bookId, string body, Guid clientId, Guid parentMessageId)
        => SendTextCore(bookId, body, clientId, parentMessageId);

    private async Task SendTextCore(Guid bookId, string body, Guid? clientId, Guid? parentMessageId)
    {
        try
        {
            var sender = await GetConnUserAsync();
            await messageSend.SendTextAsync(GetUserId(), sender, bookId, body, clientId, parentMessageId, DeviceToken);
        }
        catch (MessageSendException ex) { throw new HubException(ex.Message); }
    }

    public Task SendVoiceMessage(Guid bookId, string mediaUrl, int durationSeconds, Guid? clientId = null)
        => SendVoiceCore(bookId, mediaUrl, durationSeconds, clientId, null);
    public Task SendVoiceReply(Guid bookId, string mediaUrl, int durationSeconds, Guid clientId, Guid parentMessageId)
        => SendVoiceCore(bookId, mediaUrl, durationSeconds, clientId, parentMessageId);

    private async Task SendVoiceCore(Guid bookId, string mediaUrl, int durationSeconds, Guid? clientId, Guid? parentMessageId)
    {
        try
        {
            var sender = await GetConnUserAsync();
            await messageSend.SendVoiceAsync(GetUserId(), sender, bookId, mediaUrl, durationSeconds, clientId, parentMessageId, DeviceToken);
        }
        catch (MessageSendException ex) { throw new HubException(ex.Message); }
    }

    public Task SendPhotoMessage(Guid bookId, string mediaUrl, Guid? clientId = null)
        => SendPhotoCore(bookId, mediaUrl, clientId, null);
    public Task SendPhotoReply(Guid bookId, string mediaUrl, Guid clientId, Guid parentMessageId)
        => SendPhotoCore(bookId, mediaUrl, clientId, parentMessageId);

    private async Task SendPhotoCore(Guid bookId, string mediaUrl, Guid? clientId, Guid? parentMessageId)
    {
        try
        {
            var sender = await GetConnUserAsync();
            await messageSend.SendPhotoAsync(GetUserId(), sender, bookId, mediaUrl, clientId, parentMessageId, DeviceToken);
        }
        catch (MessageSendException ex) { throw new HubException(ex.Message); }
    }

    public Task SendVideoMessage(Guid bookId, string mediaUrl, Guid? clientId = null)
        => SendVideoCore(bookId, mediaUrl, clientId, null);
    public Task SendVideoReply(Guid bookId, string mediaUrl, Guid clientId, Guid parentMessageId)
        => SendVideoCore(bookId, mediaUrl, clientId, parentMessageId);

    private async Task SendVideoCore(Guid bookId, string mediaUrl, Guid? clientId, Guid? parentMessageId)
    {
        try
        {
            var sender = await GetConnUserAsync();
            await messageSend.SendVideoAsync(GetUserId(), sender, bookId, mediaUrl, clientId, parentMessageId, DeviceToken);
        }
        catch (MessageSendException ex) { throw new HubException(ex.Message); }
    }

    public async Task EditTextMessage(Guid messageId, string newBody)
    {
        var userId = GetUserId();
        if (string.IsNullOrWhiteSpace(newBody) || newBody.Length > 4000)
            throw new HubException("Message must be 1–4000 characters.");

        var message = await db.Messages.FindAsync(messageId)
            ?? throw new HubException("Message not found.");

        if (message.SenderId != userId)
            throw new HubException("You can only edit your own messages.");
        if (message.Type != MessageType.Text)
            throw new HubException("Only text messages can be edited.");
        if (message.DeletedAt != null)
            throw new HubException("Cannot edit a deleted message.");

        message.Body = newBody;
        await db.SaveChangesAsync();

        await Clients.Group(message.BookId.ToString()!).SendAsync("MessageEdited", new
        {
            messageId,
            bookId = message.BookId,
            body = newBody
        });
    }

    public async Task DeleteMessage(Guid messageId)
    {
        var userId = GetUserId();
        var message = await db.Messages.FindAsync(messageId)
            ?? throw new HubException("Message not found.");

        if (message.SenderId != userId)
            throw new HubException("You can only delete your own messages.");

        if (message.DeletedAt != null) return;

        message.DeletedAt = DateTime.UtcNow;
        await db.SaveChangesAsync();

        await Clients.Group(message.BookId.ToString()!).SendAsync("MessageDeleted", new
        {
            messageId,
            bookId = message.BookId
        });
    }

    public async Task ForwardMessage(Guid bookId, Guid messageId)
    {
        try
        {
            var sender = await GetConnUserAsync();
            await messageSend.ForwardAsync(GetUserId(), sender, bookId, messageId, DeviceToken);
        }
        catch (MessageSendException ex) { throw new HubException(ex.Message); }
    }

    private Guid GetUserId() =>
        Guid.Parse(Context.User?.FindFirst("sub")?.Value
            ?? throw new HubException("Unauthorized"));

    // #25 — the connecting client's own APNs token, if it sent one (an unupdated client
    // won't). Cached per-connection so a send can exclude just this one device from a
    // message's fan-out instead of every device the sender owns.
    private string? DeviceToken => Context.Items["deviceToken"] as string;

    // Per-connection cache of the sender's identity + club memberships, so each send
    // doesn't re-query Users + Memberships (H10). Loaded on connect; refreshed on
    // reconnect, so a membership/approval change mid-connection is picked up next
    // connection (acceptable for this app).
    private async Task<SenderContext> GetConnUserAsync()
    {
        if (Context.Items["connUser"] is SenderContext cached) return cached;
        var conn = await messageSend.LoadSenderContextAsync(GetUserId());
        Context.Items["connUser"] = conn;
        return conn;
    }

    public override async Task OnConnectedAsync()
    {
        await GetConnUserAsync();   // warm the cache up front
        Context.Items["deviceToken"] = Context.GetHttpContext()?.Request.Query["deviceId"].FirstOrDefault();
        await base.OnConnectedAsync();
    }
}
