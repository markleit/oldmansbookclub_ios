using BookClubApi.Data;
using BookClubApi.Models;
using BookClubApi.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.SignalR;
using Microsoft.EntityFrameworkCore;

namespace BookClubApi.Hubs;

[Authorize]
public class ChatHub(AppDbContext db, NotificationService notifications) : Hub
{
    public async Task JoinBook(Guid bookId)
    {
        var userId = GetUserId();
        var book = await db.Books.FindAsync(bookId);
        if (book is null) return;

        var isMember = await db.Memberships
            .AnyAsync(m => m.UserId == userId && m.ClubId == book.ClubId);

        if (!isMember) return;

        await Groups.AddToGroupAsync(Context.ConnectionId, bookId.ToString());
    }

    public async Task SendTextMessage(Guid bookId, string body)
    {
        var (message, bookTitle) = await SaveMessageAsync(bookId, MessageType.Text, body: body);
        await BroadcastAndNotify(bookId, message, bookTitle);
    }

    public async Task SendVoiceMessage(Guid bookId, string mediaUrl, int durationSeconds)
    {
        if (!IsOwnBlobUrl(mediaUrl)) throw new HubException("Invalid media URL.");
        var (message, bookTitle) = await SaveMessageAsync(bookId, MessageType.Voice,
            mediaUrl: mediaUrl, durationSeconds: durationSeconds);
        await BroadcastAndNotify(bookId, message, bookTitle);
    }

    public async Task SendPhotoMessage(Guid bookId, string mediaUrl)
    {
        if (!IsOwnBlobUrl(mediaUrl)) throw new HubException("Invalid media URL.");
        var (message, bookTitle) = await SaveMessageAsync(bookId, MessageType.Photo, mediaUrl: mediaUrl);
        await BroadcastAndNotify(bookId, message, bookTitle);
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
        var userId = GetUserId();

        var hasSaved = await db.SavedMessages
            .AnyAsync(s => s.UserId == userId && s.MessageId == messageId);
        if (!hasSaved) throw new HubException("Message not in your saved list.");

        var original = await db.Messages.FindAsync(messageId)
            ?? throw new HubException("Message not found.");

        if (original.DeletedAt != null) throw new HubException("Cannot forward a deleted message.");

        var book = await db.Books.FindAsync(bookId)
            ?? throw new HubException("Book not found.");

        var isMember = await db.Memberships
            .AnyAsync(m => m.UserId == userId && m.ClubId == book.ClubId);
        if (!isMember) throw new HubException("Not a member of this club.");

        var (message, bookTitle) = await SaveMessageAsync(bookId, original.Type,
            body: original.Body, mediaUrl: original.MediaUrl,
            durationSeconds: original.DurationSeconds, isForwarded: true);

        await BroadcastAndNotify(bookId, message, bookTitle);
    }

    private async Task<(MessageDto dto, string bookTitle)> SaveMessageAsync(Guid bookId, MessageType type,
        string? body = null, string? mediaUrl = null, int? durationSeconds = null, bool isForwarded = false)
    {
        var userId = GetUserId();
        var user = await db.Users.FindAsync(userId)
            ?? throw new HubException("User not found");

        if (!user.IsApproved) throw new HubException("Account not approved.");

        var book = await db.Books.FindAsync(bookId)
            ?? throw new HubException("Book not found");

        var isMember = await db.Memberships
            .AnyAsync(m => m.UserId == userId && m.ClubId == book.ClubId);
        if (!isMember) throw new HubException("Not a member of this club.");

        var message = new Message
        {
            BookId = bookId,
            ClubId = book.ClubId,
            SenderId = userId,
            Type = type,
            Body = body,
            MediaUrl = mediaUrl,
            DurationSeconds = durationSeconds,
            IsForwarded = isForwarded
        };

        db.Messages.Add(message);
        await db.SaveChangesAsync();

        return (ToDto(message, user.EffectiveName, user.AvatarUrl), book.Title);
    }

    private async Task BroadcastAndNotify(Guid bookId, MessageDto dto, string bookTitle)
    {
        await Clients.Group(bookId.ToString()).SendAsync("NewMessage", dto);

        // Push to all members except the sender; iOS willPresent suppresses it if they're actively viewing that chat
        var tokens = await db.Memberships
            .Where(m => m.ClubId == dto.ClubId && m.UserId != dto.SenderId)
            .Select(m => m.User.DeviceToken)
            .Where(t => t != null)
            .Cast<string>()
            .ToListAsync();

        if (tokens.Count > 0)
            await notifications.SendNewMessageAsync(tokens, dto, bookTitle, bookId);
    }

    private Guid GetUserId() =>
        Guid.Parse(Context.User?.FindFirst("sub")?.Value
            ?? throw new HubException("Unauthorized"));

    private static bool IsOwnBlobUrl(string url) =>
        Uri.TryCreate(url, UriKind.Absolute, out var uri) &&
        uri.Scheme == "https" &&
        uri.Host.EndsWith(".blob.core.windows.net");

    private static MessageDto ToDto(Message m, string senderName, string? senderAvatarUrl) => new(
        m.Id, m.ClubId, m.SenderId, senderName, senderAvatarUrl,
        m.Type, m.Body, m.MediaUrl, m.DurationSeconds, m.SentAt,
        m.DeletedAt != null, m.IsForwarded);
}
