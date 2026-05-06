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

        if (isMember)
            await Groups.AddToGroupAsync(Context.ConnectionId, bookId.ToString());
    }

    public async Task SendTextMessage(Guid bookId, string body)
    {
        var message = await SaveMessageAsync(bookId, MessageType.Text, body: body);
        await BroadcastAndNotify(bookId, message);
    }

    public async Task SendVoiceMessage(Guid bookId, string mediaUrl, int durationSeconds)
    {
        if (!IsOwnBlobUrl(mediaUrl)) throw new HubException("Invalid media URL.");
        var message = await SaveMessageAsync(bookId, MessageType.Voice,
            mediaUrl: mediaUrl, durationSeconds: durationSeconds);
        await BroadcastAndNotify(bookId, message);
    }

    public async Task SendPhotoMessage(Guid bookId, string mediaUrl)
    {
        if (!IsOwnBlobUrl(mediaUrl)) throw new HubException("Invalid media URL.");
        var message = await SaveMessageAsync(bookId, MessageType.Photo, mediaUrl: mediaUrl);
        await BroadcastAndNotify(bookId, message);
    }

    private async Task<MessageDto> SaveMessageAsync(Guid bookId, MessageType type,
        string? body = null, string? mediaUrl = null, int? durationSeconds = null)
    {
        var userId = GetUserId();
        var user = await db.Users.FindAsync(userId)
            ?? throw new HubException("User not found");

        // Use nickname if set, fall back to display name
        var senderName = user.EffectiveName;

        var book = await db.Books.FindAsync(bookId)
            ?? throw new HubException("Book not found");

        var message = new Message
        {
            BookId = bookId,
            ClubId = book.ClubId,
            SenderId = userId,
            Type = type,
            Body = body,
            MediaUrl = mediaUrl,
            DurationSeconds = durationSeconds
        };

        db.Messages.Add(message);
        await db.SaveChangesAsync();

        return ToDto(message, senderName, user.AvatarUrl);
    }

    private async Task BroadcastAndNotify(Guid bookId, MessageDto dto)
    {
        await Clients.Group(bookId.ToString()).SendAsync("NewMessage", dto);

        var offlineTokens = await db.Memberships
            .Where(m => m.ClubId == dto.ClubId && m.UserId != dto.SenderId)
            .Select(m => m.User.DeviceToken)
            .Where(t => t != null)
            .Cast<string>()
            .ToListAsync();

        if (offlineTokens.Count > 0)
            await notifications.SendNewMessageAsync(offlineTokens, dto);
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
        m.Type, m.Body, m.MediaUrl, m.DurationSeconds, m.SentAt);
}
