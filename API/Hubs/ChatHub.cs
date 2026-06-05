using BookClubApi.Data;
using BookClubApi.Models;
using BookClubApi.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.SignalR;
using Microsoft.EntityFrameworkCore;

namespace BookClubApi.Hubs;

[Authorize]
public class ChatHub(AppDbContext db, BlobService blob, NotificationService notifications, HubRateLimiter rateLimiter, ILogger<ChatHub> logger) : Hub
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
        EnforceRateLimit();
        if (string.IsNullOrWhiteSpace(body) || body.Length > 4000)
            throw new HubException("Message must be 1–4000 characters.");
        var (message, bookTitle) = await SaveMessageAsync(bookId, MessageType.Text, body: body);
        await BroadcastAndNotify(bookId, message, bookTitle);
    }

    public async Task SendVoiceMessage(Guid bookId, string mediaUrl, int durationSeconds, Guid? clientId = null)
    {
        EnforceRateLimit();
        if (!IsOwnBlobUrl(mediaUrl)) throw new HubException("Invalid media URL.");

        if (clientId.HasValue)
        {
            var userId = GetUserId();
            var existing = await db.Messages
                .Include(m => m.Sender)
                .FirstOrDefaultAsync(m => m.ClientId == clientId && m.SenderId == userId);
            if (existing != null)
            {
                string? broadcastUrl = existing.MediaUrl;
                if (broadcastUrl != null)
                {
                    var (key, keyExpiry) = await blob.GetReadDelegationKeyAsync();
                    broadcastUrl = blob.GenerateFreshReadUrl(broadcastUrl, key, keyExpiry);
                }
                await Clients.Group(bookId.ToString())
                    .SendAsync("NewMessage", ToDto(existing, existing.Sender.EffectiveName, existing.Sender.AvatarUrl, broadcastUrl));
                return;
            }
        }

        var (message, bookTitle) = await SaveMessageAsync(bookId, MessageType.Voice,
            mediaUrl: mediaUrl, durationSeconds: durationSeconds, clientId: clientId);
        await BroadcastAndNotify(bookId, message, bookTitle);
    }

    public async Task SendPhotoMessage(Guid bookId, string mediaUrl)
    {
        System.Threading.Interlocked.Increment(ref BroadcastDiagnostics.SendPhotoMessageEntryCount);
        try
        {
            EnforceRateLimit();
            if (!IsOwnBlobUrl(mediaUrl)) throw new HubException("Invalid media URL.");
            var (message, bookTitle) = await SaveMessageAsync(bookId, MessageType.Photo, mediaUrl: mediaUrl);
            await BroadcastAndNotify(bookId, message, bookTitle);
        }
        catch (Exception ex)
        {
            BroadcastDiagnostics.LastSendPhotoError = $"{DateTime.UtcNow:O} {ex.GetType().Name}: {ex.Message}";
            throw;
        }
    }

    public async Task SendVideoMessage(Guid bookId, string mediaUrl)
    {
        EnforceRateLimit();
        if (!IsOwnBlobUrl(mediaUrl)) throw new HubException("Invalid media URL.");
        var (message, bookTitle) = await SaveMessageAsync(bookId, MessageType.Video, mediaUrl: mediaUrl);
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
        EnforceRateLimit();
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

        // Strip any stale SAS from the stored URL — SaveMessageAsync stores plain URL and generates fresh SAS for broadcast
        var plainMediaUrl = original.MediaUrl?.Split('?')[0];
        var (message, bookTitle) = await SaveMessageAsync(bookId, original.Type,
            body: original.Body, mediaUrl: plainMediaUrl,
            durationSeconds: original.DurationSeconds, isForwarded: true);

        await BroadcastAndNotify(bookId, message, bookTitle);
    }

    private async Task<(MessageDto dto, string bookTitle)> SaveMessageAsync(Guid bookId, MessageType type,
        string? body = null, string? mediaUrl = null, int? durationSeconds = null, bool isForwarded = false, Guid? clientId = null)
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
            IsForwarded = isForwarded,
            ClientId = clientId
        };

        db.Messages.Add(message);
        await db.SaveChangesAsync();

        string? broadcastMediaUrl = mediaUrl;
        Console.WriteLine($"[DIAG] SaveMessageAsync entered, mediaUrl={(mediaUrl == null ? "<null>" : "<set>")}, type={type}");
        if (mediaUrl != null)
        {
            try
            {
                var (key, keyExpiry) = await blob.GetReadDelegationKeyAsync();
                broadcastMediaUrl = blob.GenerateFreshReadUrl(mediaUrl, key, keyExpiry);
                Console.WriteLine($"[DIAG] broadcast URL hasQuery={broadcastMediaUrl?.Contains('?') == true} length={broadcastMediaUrl?.Length ?? 0}");
            }
            catch (Exception ex)
            {
                Console.WriteLine($"[DIAG] GenerateFreshReadUrl THREW: {ex.GetType().Name}: {ex.Message}");
            }
        }

        return (ToDto(message, user.EffectiveName, user.AvatarUrl, broadcastMediaUrl), book.Title);
    }

    private async Task BroadcastAndNotify(Guid bookId, MessageDto dto, string bookTitle)
    {
        BroadcastDiagnostics.LastBroadcastMediaUrl = dto.MediaUrl;
        BroadcastDiagnostics.LastBroadcastAt = DateTime.UtcNow;
        System.Threading.Interlocked.Increment(ref BroadcastDiagnostics.BroadcastCount);
        Console.WriteLine($"[DIAG] BroadcastAndNotify: dto.MediaUrl hasQuery={dto.MediaUrl?.Contains('?') == true} length={dto.MediaUrl?.Length ?? 0}");
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

    private void EnforceRateLimit()
    {
        if (!rateLimiter.TryAcquire(GetUserId()))
            throw new HubException("Slow down — too many messages. Try again in a minute.");
    }

    private const string AllowedBlobHost = "oldmansbookclubstore.blob.core.windows.net";

    private static bool IsOwnBlobUrl(string url) =>
        Uri.TryCreate(url, UriKind.Absolute, out var uri) &&
        uri.Scheme == "https" &&
        uri.Host == AllowedBlobHost;

    private static MessageDto ToDto(Message m, string senderName, string? senderAvatarUrl, string? broadcastMediaUrl = null)
    {
        var deleted = m.DeletedAt != null;
        return new MessageDto(
            m.Id, m.ClubId,
            deleted ? Guid.Empty : m.SenderId,
            deleted ? "" : senderName,
            deleted ? null : senderAvatarUrl,
            m.Type,
            deleted ? null : m.Body,
            deleted ? null : (broadcastMediaUrl ?? m.MediaUrl),
            deleted ? null : m.DurationSeconds,
            m.SentAt,
            deleted, m.IsForwarded, m.ClientId);
    }
}
