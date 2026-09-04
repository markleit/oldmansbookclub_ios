using BookClubApi.Data;
using BookClubApi.Hubs;
using BookClubApi.Models;
using Microsoft.AspNetCore.SignalR;
using Microsoft.EntityFrameworkCore;

namespace BookClubApi.Services;

// Thrown for any client-caused send failure (validation, membership, not found, rate limit).
// ChatHub wraps this in a HubException; MessagesController turns it into a 400 — same
// messages reach the user either way.
public class MessageSendException(string message) : Exception(message);

// Per-sender info needed by every send — mirrors ChatHub's old per-connection ConnUser cache.
// The hub still caches this in Context.Items (H10); a REST call just loads it fresh, which is
// fine since it's one query per HTTP request, not per keystroke.
public record SenderContext(bool IsApproved, string EffectiveName, string? AvatarUrl, HashSet<Guid> ClubIds);

// Extracted from ChatHub so both the SignalR hub (live, chat-open sends) and the REST
// endpoint (background-safe sends via a background URLSession, see BackgroundUploadService)
// share one implementation of "save a message + broadcast it + queue the push." Broadcasting
// uses IHubContext<ChatHub> instead of the Hub's own Clients/Context, which is what makes this
// callable from a plain controller.
public class MessageSendService(AppDbContext db, BlobService blob, NotificationQueue notificationQueue,
    HubRateLimiter rateLimiter, IHubContext<ChatHub> hub)
{
    // Per-type upload caps, enforced server-side so a misbehaving client can't bypass the
    // client-side checks. Generous headroom over the expected encoded sizes.
    private const long MaxVoiceBytes = 25L * 1024 * 1024;   // ~15 min voice is a few MB
    private const long MaxPhotoBytes = 15L * 1024 * 1024;   // resized client-side to ~<1 MB
    private const long MaxVideoBytes = 100L * 1024 * 1024;  // 100 MB cap (matches client)

    public async Task<SenderContext> LoadSenderContextAsync(Guid userId)
    {
        var user = await db.Users.FindAsync(userId) ?? throw new MessageSendException("User not found.");
        var clubIds = await db.Memberships.Where(m => m.UserId == userId).Select(m => m.ClubId).ToListAsync();
        return new SenderContext(user.IsApproved, user.EffectiveName, user.AvatarUrl, clubIds.ToHashSet());
    }

    private void EnforceRateLimit(Guid userId)
    {
        if (!rateLimiter.TryAcquire(userId))
            throw new MessageSendException("Slow down — too many messages. Try again in a minute.");
    }

    // Still a strict allow-list — a client can only hand us a URL on our own storage account —
    // but sourced from configuration rather than a literal. It was hardcoded to production's
    // account, which meant dev rejected its own uploads ("Invalid media URL." on every voice,
    // photo and video send) once #120 moved dev onto a separate storage account. Production
    // behaviour is unchanged: BlobService resolves to the same host there.
    private bool IsOwnBlobUrl(string url) =>
        Uri.TryCreate(url, UriKind.Absolute, out var uri) &&
        uri.Scheme == "https" &&
        uri.Host == blob.AccountHost;

    private async Task EnforceBlobSizeAsync(string mediaUrl, long maxBytes, string label)
    {
        var size = await blob.GetBlobSizeAsync(mediaUrl);
        if (size is > 0 && size > maxBytes)
            throw new MessageSendException($"{label} is too large (max {maxBytes / (1024 * 1024)} MB).");
    }

    public async Task<MessageDto> SendTextAsync(Guid userId, SenderContext sender, Guid bookId, string body,
        Guid? clientId, Guid? parentMessageId, string? senderDeviceToken)
    {
        EnforceRateLimit(userId);
        if (string.IsNullOrWhiteSpace(body) || body.Length > 4000)
            throw new MessageSendException("Message must be 1–4000 characters.");
        if (await TryRebroadcastExistingAsync(bookId, userId, clientId) is { } existing) return existing;

        var (dto, bookTitle, alreadyBroadcast) = await SaveMessageAsync(userId, sender, bookId, MessageType.Text,
            body: body, clientId: clientId, parentMessageId: parentMessageId);
        if (!alreadyBroadcast) await BroadcastAndNotify(bookId, dto, bookTitle, senderDeviceToken);
        return dto;
    }

    public async Task<MessageDto> SendVoiceAsync(Guid userId, SenderContext sender, Guid bookId, string mediaUrl,
        int durationSeconds, Guid? clientId, Guid? parentMessageId, string? senderDeviceToken)
    {
        EnforceRateLimit(userId);
        if (!IsOwnBlobUrl(mediaUrl)) throw new MessageSendException("Invalid media URL.");
        if (await TryRebroadcastExistingAsync(bookId, userId, clientId) is { } existing) return existing;
        await EnforceBlobSizeAsync(mediaUrl, MaxVoiceBytes, "Voice message");

        var (dto, bookTitle, alreadyBroadcast) = await SaveMessageAsync(userId, sender, bookId, MessageType.Voice,
            mediaUrl: mediaUrl, durationSeconds: durationSeconds, clientId: clientId, parentMessageId: parentMessageId);
        if (!alreadyBroadcast) await BroadcastAndNotify(bookId, dto, bookTitle, senderDeviceToken);
        return dto;
    }

    public async Task<MessageDto> SendPhotoAsync(Guid userId, SenderContext sender, Guid bookId, string mediaUrl,
        Guid? clientId, Guid? parentMessageId, string? senderDeviceToken)
    {
        EnforceRateLimit(userId);
        if (!IsOwnBlobUrl(mediaUrl)) throw new MessageSendException("Invalid media URL.");
        if (await TryRebroadcastExistingAsync(bookId, userId, clientId) is { } existing) return existing;
        await EnforceBlobSizeAsync(mediaUrl, MaxPhotoBytes, "Photo");

        var (dto, bookTitle, alreadyBroadcast) = await SaveMessageAsync(userId, sender, bookId, MessageType.Photo,
            mediaUrl: mediaUrl, clientId: clientId, parentMessageId: parentMessageId);
        if (!alreadyBroadcast) await BroadcastAndNotify(bookId, dto, bookTitle, senderDeviceToken);
        return dto;
    }

    public async Task<MessageDto> SendVideoAsync(Guid userId, SenderContext sender, Guid bookId, string mediaUrl,
        Guid? clientId, Guid? parentMessageId, string? senderDeviceToken)
    {
        EnforceRateLimit(userId);
        if (!IsOwnBlobUrl(mediaUrl)) throw new MessageSendException("Invalid media URL.");
        if (await TryRebroadcastExistingAsync(bookId, userId, clientId) is { } existing) return existing;
        await EnforceBlobSizeAsync(mediaUrl, MaxVideoBytes, "Video");

        var (dto, bookTitle, alreadyBroadcast) = await SaveMessageAsync(userId, sender, bookId, MessageType.Video,
            mediaUrl: mediaUrl, clientId: clientId, parentMessageId: parentMessageId);
        if (!alreadyBroadcast) await BroadcastAndNotify(bookId, dto, bookTitle, senderDeviceToken);
        return dto;
    }

    public async Task<MessageDto> ForwardAsync(Guid userId, SenderContext sender, Guid bookId, Guid messageId,
        string? senderDeviceToken)
    {
        EnforceRateLimit(userId);
        var hasSaved = await db.SavedMessages.AnyAsync(s => s.UserId == userId && s.MessageId == messageId);
        if (!hasSaved) throw new MessageSendException("Message not in your saved list.");

        var original = await db.Messages.FindAsync(messageId) ?? throw new MessageSendException("Message not found.");
        if (original.DeletedAt != null) throw new MessageSendException("Cannot forward a deleted message.");

        var book = await db.Books.FindAsync(bookId) ?? throw new MessageSendException("Book not found.");
        if (!sender.ClubIds.Contains(book.ClubId)) throw new MessageSendException("Not a member of this club.");

        // Strip any stale SAS — SaveMessageAsync stores the plain URL and generates a fresh SAS for broadcast.
        var plainMediaUrl = original.MediaUrl?.Split('?')[0];
        var (dto, bookTitle, alreadyBroadcast) = await SaveMessageAsync(userId, sender, bookId, original.Type,
            body: original.Body, mediaUrl: plainMediaUrl, durationSeconds: original.DurationSeconds, isForwarded: true);
        // Forwards carry no clientId, so alreadyBroadcast should never trip here — defensive only.
        if (!alreadyBroadcast) await BroadcastAndNotify(bookId, dto, bookTitle, senderDeviceToken);
        return dto;
    }

    // Idempotent re-send protection: if a message with this clientId already exists for this
    // user, re-broadcast the stored version (fresh SAS) and hand its dto back instead of
    // creating a duplicate. A retried REST POST (background URLSession retry, client retry
    // after a dropped response) lands here safely.
    private async Task<MessageDto?> TryRebroadcastExistingAsync(Guid bookId, Guid userId, Guid? clientId)
    {
        if (!clientId.HasValue) return null;
        var existing = await db.Messages
            .Include(m => m.Sender)
            .FirstOrDefaultAsync(m => m.ClientId == clientId && m.SenderId == userId);
        if (existing == null) return null;

        string? broadcastUrl = existing.MediaUrl;
        if (broadcastUrl != null)
        {
            var (key, keyExpiry) = await blob.GetReadDelegationKeyAsync();
            broadcastUrl = blob.GenerateFreshReadUrl(broadcastUrl, key, keyExpiry);
        }
        var dto = ToDto(existing, existing.Sender.EffectiveName, existing.Sender.AvatarUrl, broadcastUrl);
        await hub.Clients.Group(bookId.ToString()).SendAsync("NewMessage", dto);
        return dto;
    }

    // SQL Server: 2627 = unique constraint violation, 2601 = unique index violation. Either
    // means a row with this (SenderId, ClientId) already exists — i.e. a duplicate re-send.
    private static bool IsUniqueClientIdViolation(DbUpdateException ex)
        => ex.InnerException is Microsoft.Data.SqlClient.SqlException sql
           && (sql.Number == 2601 || sql.Number == 2627);

    // alreadyBroadcast=true means a concurrent send with the same clientId won the insert race:
    // TryRebroadcastExistingAsync already broadcast the winner in here, so the caller must NOT
    // call BroadcastAndNotify again (no second broadcast, no duplicate push). The DB unique
    // index on (SenderId, ClientId) is what makes this race-safe.
    private async Task<(MessageDto dto, string bookTitle, bool alreadyBroadcast)> SaveMessageAsync(
        Guid userId, SenderContext sender, Guid bookId, MessageType type,
        string? body = null, string? mediaUrl = null, int? durationSeconds = null, bool isForwarded = false,
        Guid? clientId = null, Guid? parentMessageId = null)
    {
        if (!sender.IsApproved) throw new MessageSendException("Account not approved.");

        var book = await db.Books.FindAsync(bookId) ?? throw new MessageSendException("Book not found");
        if (!sender.ClubIds.Contains(book.ClubId)) throw new MessageSendException("Not a member of this club.");

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
            ClientId = clientId,
            ParentMessageId = parentMessageId
        };

        db.Messages.Add(message);
        try
        {
            await db.SaveChangesAsync();
        }
        catch (DbUpdateException ex) when (IsUniqueClientIdViolation(ex))
        {
            db.Entry(message).State = EntityState.Detached;
            var winner = await TryRebroadcastExistingAsync(bookId, userId, clientId)
                ?? throw new MessageSendException("Duplicate send could not be resolved.");
            return (winner, book.Title, true);
        }

        string? broadcastMediaUrl = mediaUrl;
        if (mediaUrl != null)
        {
            var (key, keyExpiry) = await blob.GetReadDelegationKeyAsync();
            broadcastMediaUrl = blob.GenerateFreshReadUrl(mediaUrl, key, keyExpiry);
        }

        // Build the quoted-reply preview from the parent, if this is a reply.
        string? parentSenderName = null, parentPreview = null;
        DateTime? parentSentAt = null;
        if (parentMessageId is Guid pid)
        {
            var p = await db.Messages.Where(x => x.Id == pid)
                .Select(x => new { x.Type, x.Body, x.Transcript, x.SentAt, Deleted = x.DeletedAt != null, Name = x.Sender.Nickname ?? x.Sender.DisplayName })
                .FirstOrDefaultAsync();
            if (p is not null)
            {
                parentSenderName = p.Deleted ? null : p.Name;
                parentPreview = ParentPreviewText(p.Type, p.Body, p.Transcript, p.Deleted);
                parentSentAt = p.Deleted ? null : p.SentAt;
            }
        }

        var dto = ToDto(message, sender.EffectiveName, sender.AvatarUrl, broadcastMediaUrl,
            parentMessageId, parentSenderName, parentPreview, parentSentAt);
        return (dto, book.Title, false);
    }

    // Short text shown in a quoted-reply chip for the parent message. For voice, prefer the
    // uploaded transcript ("🎤 first words…") over the generic label.
    private const int ParentPreviewMaxChars = 120;
    private static string? ParentPreviewText(MessageType type, string? body, string? transcript, bool deleted) =>
        deleted ? "Deleted message" : type switch
        {
            MessageType.Text => Snippet(body),
            MessageType.Voice => string.IsNullOrWhiteSpace(transcript) ? "🎤 Voice message" : "🎤 " + Snippet(transcript),
            MessageType.Photo => "📷 Photo",
            MessageType.Video => "🎬 Video",
            _ => null
        };

    private static string? Snippet(string? s)
    {
        if (string.IsNullOrEmpty(s)) return s;
        return s.Length <= ParentPreviewMaxChars ? s : s[..ParentPreviewMaxChars].TrimEnd() + "…";
    }

    private async Task BroadcastAndNotify(Guid bookId, MessageDto dto, string bookTitle, string? senderDeviceToken)
    {
        await hub.Clients.Group(bookId.ToString()).SendAsync("NewMessage", dto);

        // #24 — hand the APNs fan-out to the background dispatcher so this doesn't block the
        // caller (hub invoke return, or the REST response) on a per-member badge query + APNs round-trip.
        notificationQueue.Enqueue(new NotificationJob(bookId, dto, bookTitle, senderDeviceToken));
    }

    private static MessageDto ToDto(Message m, string senderName, string? senderAvatarUrl, string? broadcastMediaUrl = null,
        Guid? parentMessageId = null, string? parentSenderName = null, string? parentPreview = null, DateTime? parentSentAt = null)
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
            deleted, m.IsForwarded, m.ClientId,
            deleted ? null : parentMessageId,
            deleted ? null : parentSenderName,
            deleted ? null : parentPreview,
            deleted ? null : parentSentAt,
            deleted ? null : m.Transcript);
    }
}
