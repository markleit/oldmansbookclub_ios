using BookClubApi.Data;
using BookClubApi.Models;
using BookClubApi.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.SignalR;
using Microsoft.EntityFrameworkCore;

namespace BookClubApi.Hubs;

[Authorize]
public class ChatHub(AppDbContext db, BlobService blob, NotificationService notifications, HubRateLimiter rateLimiter) : Hub
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
    // contract — adding a param breaks older clients. Replies therefore go through
    // SEPARATE *Reply methods rather than an optional param on the originals, so the
    // live App Store client keeps working unchanged.
    public Task SendTextMessage(Guid bookId, string body, Guid? clientId = null)
        => SendTextCore(bookId, body, clientId, null);
    public Task SendTextReply(Guid bookId, string body, Guid clientId, Guid parentMessageId)
        => SendTextCore(bookId, body, clientId, parentMessageId);

    private async Task SendTextCore(Guid bookId, string body, Guid? clientId, Guid? parentMessageId)
    {
        EnforceRateLimit();
        if (string.IsNullOrWhiteSpace(body) || body.Length > 4000)
            throw new HubException("Message must be 1–4000 characters.");
        // Idempotent re-send + echo the clientId back so the client matches the optimistic
        // bubble by id (not by body — identical consecutive sends raced the body key).
        if (await TryRebroadcastExistingAsync(bookId, clientId)) return;
        var (message, bookTitle) = await SaveMessageAsync(bookId, MessageType.Text, body: body, clientId: clientId, parentMessageId: parentMessageId);
        await BroadcastAndNotify(bookId, message, bookTitle);
    }

    // Per-type upload caps, enforced server-side so a misbehaving client can't bypass
    // the client-side checks. Generous headroom over the expected encoded sizes.
    private const long MaxVoiceBytes = 25L * 1024 * 1024;   // ~15 min voice is a few MB
    private const long MaxPhotoBytes = 15L * 1024 * 1024;   // resized client-side to ~<1 MB
    private const long MaxVideoBytes = 100L * 1024 * 1024;  // 100 MB cap (matches client)

    // Reject if the already-uploaded blob exceeds the type's cap. (A rejected upload
    // orphans its blob — only hit by a misbehaving client past the client check; the
    // lifecycle GC in #31 will reap it.)
    private async Task EnforceBlobSizeAsync(string mediaUrl, long maxBytes, string label)
    {
        var size = await blob.GetBlobSizeAsync(mediaUrl);
        if (size is > 0 && size > maxBytes)
            throw new HubException($"{label} is too large (max {maxBytes / (1024 * 1024)} MB).");
    }

    public Task SendVoiceMessage(Guid bookId, string mediaUrl, int durationSeconds, Guid? clientId = null)
        => SendVoiceCore(bookId, mediaUrl, durationSeconds, clientId, null);
    public Task SendVoiceReply(Guid bookId, string mediaUrl, int durationSeconds, Guid clientId, Guid parentMessageId)
        => SendVoiceCore(bookId, mediaUrl, durationSeconds, clientId, parentMessageId);

    private async Task SendVoiceCore(Guid bookId, string mediaUrl, int durationSeconds, Guid? clientId, Guid? parentMessageId)
    {
        EnforceRateLimit();
        if (!IsOwnBlobUrl(mediaUrl)) throw new HubException("Invalid media URL.");
        if (await TryRebroadcastExistingAsync(bookId, clientId)) return;
        await EnforceBlobSizeAsync(mediaUrl, MaxVoiceBytes, "Voice message");

        var (message, bookTitle) = await SaveMessageAsync(bookId, MessageType.Voice,
            mediaUrl: mediaUrl, durationSeconds: durationSeconds, clientId: clientId, parentMessageId: parentMessageId);
        await BroadcastAndNotify(bookId, message, bookTitle);
    }

    public Task SendPhotoMessage(Guid bookId, string mediaUrl, Guid? clientId = null)
        => SendPhotoCore(bookId, mediaUrl, clientId, null);
    public Task SendPhotoReply(Guid bookId, string mediaUrl, Guid clientId, Guid parentMessageId)
        => SendPhotoCore(bookId, mediaUrl, clientId, parentMessageId);

    private async Task SendPhotoCore(Guid bookId, string mediaUrl, Guid? clientId, Guid? parentMessageId)
    {
        EnforceRateLimit();
        if (!IsOwnBlobUrl(mediaUrl)) throw new HubException("Invalid media URL.");
        if (await TryRebroadcastExistingAsync(bookId, clientId)) return;
        await EnforceBlobSizeAsync(mediaUrl, MaxPhotoBytes, "Photo");

        var (message, bookTitle) = await SaveMessageAsync(bookId, MessageType.Photo,
            mediaUrl: mediaUrl, clientId: clientId, parentMessageId: parentMessageId);
        await BroadcastAndNotify(bookId, message, bookTitle);
    }

    public Task SendVideoMessage(Guid bookId, string mediaUrl, Guid? clientId = null)
        => SendVideoCore(bookId, mediaUrl, clientId, null);
    public Task SendVideoReply(Guid bookId, string mediaUrl, Guid clientId, Guid parentMessageId)
        => SendVideoCore(bookId, mediaUrl, clientId, parentMessageId);

    private async Task SendVideoCore(Guid bookId, string mediaUrl, Guid? clientId, Guid? parentMessageId)
    {
        EnforceRateLimit();
        if (!IsOwnBlobUrl(mediaUrl)) throw new HubException("Invalid media URL.");
        if (await TryRebroadcastExistingAsync(bookId, clientId)) return;
        await EnforceBlobSizeAsync(mediaUrl, MaxVideoBytes, "Video");

        var (message, bookTitle) = await SaveMessageAsync(bookId, MessageType.Video,
            mediaUrl: mediaUrl, clientId: clientId, parentMessageId: parentMessageId);
        await BroadcastAndNotify(bookId, message, bookTitle);
    }

    // Idempotent re-send protection: if a message with this clientId already exists
    // for this user, re-broadcast the stored version with a fresh SAS instead of creating
    // a duplicate. Returns true if rebroadcast happened and the caller should bail out.
    private async Task<bool> TryRebroadcastExistingAsync(Guid bookId, Guid? clientId)
    {
        if (!clientId.HasValue) return false;
        var userId = GetUserId();
        var existing = await db.Messages
            .Include(m => m.Sender)
            .FirstOrDefaultAsync(m => m.ClientId == clientId && m.SenderId == userId);
        if (existing == null) return false;

        string? broadcastUrl = existing.MediaUrl;
        if (broadcastUrl != null)
        {
            var (key, keyExpiry) = await blob.GetReadDelegationKeyAsync();
            broadcastUrl = blob.GenerateFreshReadUrl(broadcastUrl, key, keyExpiry);
        }
        await Clients.Group(bookId.ToString())
            .SendAsync("NewMessage", ToDto(existing, existing.Sender.EffectiveName, existing.Sender.AvatarUrl, broadcastUrl));
        return true;
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

        var conn = await GetConnUserAsync();
        if (!conn.ClubIds.Contains(book.ClubId)) throw new HubException("Not a member of this club.");

        // Strip any stale SAS from the stored URL — SaveMessageAsync stores plain URL and generates fresh SAS for broadcast
        var plainMediaUrl = original.MediaUrl?.Split('?')[0];
        var (message, bookTitle) = await SaveMessageAsync(bookId, original.Type,
            body: original.Body, mediaUrl: plainMediaUrl,
            durationSeconds: original.DurationSeconds, isForwarded: true);

        await BroadcastAndNotify(bookId, message, bookTitle);
    }

    private async Task<(MessageDto dto, string bookTitle)> SaveMessageAsync(Guid bookId, MessageType type,
        string? body = null, string? mediaUrl = null, int? durationSeconds = null, bool isForwarded = false,
        Guid? clientId = null, Guid? parentMessageId = null)
    {
        var userId = GetUserId();
        var conn = await GetConnUserAsync();
        if (!conn.IsApproved) throw new HubException("Account not approved.");

        var book = await db.Books.FindAsync(bookId)
            ?? throw new HubException("Book not found");

        if (!conn.ClubIds.Contains(book.ClubId)) throw new HubException("Not a member of this club.");

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
        await db.SaveChangesAsync();

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

        return (ToDto(message, conn.EffectiveName, conn.AvatarUrl, broadcastMediaUrl,
            parentMessageId, parentSenderName, parentPreview, parentSentAt), book.Title);
    }

    // Short text shown in a quoted-reply chip for the parent message. For voice, prefer
    // the uploaded transcript ("🎤 first words…") over the generic label.
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

    private async Task BroadcastAndNotify(Guid bookId, MessageDto dto, string bookTitle)
    {
        await Clients.Group(bookId.ToString()).SendAsync("NewMessage", dto);

        // The sender's own device token can be registered to other accounts too (the
        // same physical device signed in as multiple users — dev/test logins — over
        // time). Excluding by UserId isn't enough: another account's membership carries
        // the sender's device token, so the sender's phone gets a push for its own
        // message. Exclude the sender's device token(s) explicitly, and Distinct() so a
        // device shared across members isn't notified more than once.
        var senderTokens = await db.Users
            .Where(u => u.Id == dto.SenderId && u.DeviceToken != null)
            .Select(u => u.DeviceToken!)
            .ToListAsync();

        // Per recipient (not just per token) so each push carries that user's own total
        // unread count for the app icon badge. Distinct device tokens, sender's device
        // excluded.
        var recipients = await db.Memberships
            .Where(m => m.ClubId == dto.ClubId && m.UserId != dto.SenderId && m.User.DeviceToken != null)
            .Select(m => new { m.UserId, Token = m.User.DeviceToken! })
            .Distinct()
            .ToListAsync();

        var seenTokens = new HashSet<string>(senderTokens);
        foreach (var r in recipients)
        {
            if (!seenTokens.Add(r.Token)) continue;   // skip sender's device + dupes
            var badge = await UnreadCalculator.TotalAsync(db, r.UserId);
            await notifications.SendNewMessageAsync([r.Token], dto, bookTitle, bookId, badge);
        }
    }

    private Guid GetUserId() =>
        Guid.Parse(Context.User?.FindFirst("sub")?.Value
            ?? throw new HubException("Unauthorized"));

    // Per-connection cache of the sender's identity + club memberships, so each send
    // doesn't re-query Users + Memberships (H10). Loaded on connect; refreshed on
    // reconnect, so a membership/approval change mid-connection is picked up next
    // connection (acceptable for this app).
    private sealed record ConnUser(bool IsApproved, string EffectiveName, string? AvatarUrl, HashSet<Guid> ClubIds);

    private async Task<ConnUser> GetConnUserAsync()
    {
        if (Context.Items["connUser"] is ConnUser cached) return cached;
        var userId = GetUserId();
        var user = await db.Users.FindAsync(userId) ?? throw new HubException("User not found");
        var clubIds = await db.Memberships.Where(m => m.UserId == userId).Select(m => m.ClubId).ToListAsync();
        var conn = new ConnUser(user.IsApproved, user.EffectiveName, user.AvatarUrl, clubIds.ToHashSet());
        Context.Items["connUser"] = conn;
        return conn;
    }

    public override async Task OnConnectedAsync()
    {
        await GetConnUserAsync();   // warm the cache up front
        await base.OnConnectedAsync();
    }

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
            deleted ? null : parentSentAt);
    }
}
