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

// #204 — the one refusal that is NOT final: the sender is over the per-minute limit and may send
// again after `RetryAfter`. MessagesController answers 429 + Retry-After (with the same {error}
// body, so 2.1-and-older clients still show the message), and a 2.2 client waits and resends
// instead of giving up. Subclass of MessageSendException so the hub's catch is unchanged.
public class MessageRateLimitedException(TimeSpan retryAfter)
    : MessageSendException("Slow down — too many messages. Try again in a minute.")
{
    public TimeSpan RetryAfter { get; } = retryAfter;
}

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
    HubRateLimiter rateLimiter, IHubContext<ChatHub> hub, TimeProvider time)
{
    /// #204 — how far back a client's "tapped Send at" time is honoured. Long enough for any real
    /// outage or a phone left off over a weekend; short enough that a phone with a badly wrong
    /// clock can't bury a message months back in a chat.
    public static readonly TimeSpan MaxSentAtAge = TimeSpan.FromDays(7);

    /// The sender's tap time, clamped to [received − 7 days, received]: never in the future (a
    /// fast phone clock), never older than the window. No time given (older clients) → received.
    public static DateTime ClampSentAt(DateTime? clientSentAt, DateTime receivedAt)
    {
        if (clientSentAt is not DateTime sent) return receivedAt;
        sent = sent.Kind == DateTimeKind.Local ? sent.ToUniversalTime() : DateTime.SpecifyKind(sent, DateTimeKind.Utc);
        if (sent > receivedAt) return receivedAt;
        var earliest = receivedAt - MaxSentAtAge;
        return sent < earliest ? earliest : sent;
    }

    // Per-type upload caps, enforced server-side so a misbehaving client can't bypass the
    // client-side checks. Generous headroom over the expected encoded sizes.
    private const long MaxVoiceBytes = 25L * 1024 * 1024;   // ~15 min voice is a few MB
    private const long MaxPhotoBytes = 15L * 1024 * 1024;   // resized client-side to 2048 px, ~1 MB
    private const long MaxVideoBytes = 100L * 1024 * 1024;  // 100 MB cap (matches client)

    /// #204 — the largest request body the file-body send accepts: the voice cap (the bigger of
    /// the two kinds it takes) plus headroom. MessagesController's [RequestSizeLimit] uses it so
    /// Kestrel refuses anything larger before a byte is read; the per-kind cap below is the
    /// precise check. Video is deliberately not accepted this way (see SendMediaFileAsync).
    public const long MaxMediaFileRequestBytes = MaxVoiceBytes + 1024 * 1024;

    public async Task<SenderContext> LoadSenderContextAsync(Guid userId)
    {
        var user = await db.Users.FindAsync(userId) ?? throw new MessageSendException("User not found.");
        var clubIds = await db.Memberships.Where(m => m.UserId == userId).Select(m => m.ClubId).ToListAsync();
        return new SenderContext(user.IsApproved, user.EffectiveName, user.AvatarUrl, clubIds.ToHashSet());
    }

    // #204 — called AFTER the clientId dedup check in every send, never before: a re-send of a
    // message the server already has (a retry whose response was lost, or the direct and
    // background copies of one send racing) creates nothing, so it must not spend the sender's
    // budget — counted twice, a 10-photo batch could trip the limit on its own.
    private void EnforceRateLimit(Guid userId)
    {
        if (!rateLimiter.TryAcquire(userId, out var retryAfter))
            throw new MessageRateLimitedException(retryAfter);
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
        Guid? clientId, Guid? parentMessageId, string? senderDeviceToken, DateTime? sentAt = null)
    {
        if (string.IsNullOrWhiteSpace(body) || body.Length > 4000)
            throw new MessageSendException("Message must be 1–4000 characters.");
        if (await TryRebroadcastExistingAsync(bookId, userId, clientId) is { } existing) return existing;
        EnforceRateLimit(userId);

        var (dto, bookTitle, alreadyBroadcast) = await SaveMessageAsync(userId, sender, bookId, MessageType.Text,
            body: body, clientId: clientId, parentMessageId: parentMessageId, clientSentAt: sentAt);
        if (!alreadyBroadcast) await BroadcastAndNotify(bookId, dto, bookTitle, senderDeviceToken);
        return dto;
    }

    public async Task<MessageDto> SendVoiceAsync(Guid userId, SenderContext sender, Guid bookId, string mediaUrl,
        int durationSeconds, Guid? clientId, Guid? parentMessageId, string? senderDeviceToken, DateTime? sentAt = null)
    {
        if (!IsOwnBlobUrl(mediaUrl)) throw new MessageSendException("Invalid media URL.");
        if (await TryRebroadcastExistingAsync(bookId, userId, clientId) is { } existing) return existing;
        EnforceRateLimit(userId);
        await EnforceBlobSizeAsync(mediaUrl, MaxVoiceBytes, "Voice message");

        var (dto, bookTitle, alreadyBroadcast) = await SaveMessageAsync(userId, sender, bookId, MessageType.Voice,
            mediaUrl: mediaUrl, durationSeconds: durationSeconds, clientId: clientId, parentMessageId: parentMessageId,
            clientSentAt: sentAt);
        if (!alreadyBroadcast) await BroadcastAndNotify(bookId, dto, bookTitle, senderDeviceToken);
        return dto;
    }

    public async Task<MessageDto> SendPhotoAsync(Guid userId, SenderContext sender, Guid bookId, string mediaUrl,
        Guid? clientId, Guid? parentMessageId, string? senderDeviceToken, DateTime? sentAt = null)
    {
        if (!IsOwnBlobUrl(mediaUrl)) throw new MessageSendException("Invalid media URL.");
        if (await TryRebroadcastExistingAsync(bookId, userId, clientId) is { } existing) return existing;
        EnforceRateLimit(userId);
        await EnforceBlobSizeAsync(mediaUrl, MaxPhotoBytes, "Photo");

        var (dto, bookTitle, alreadyBroadcast) = await SaveMessageAsync(userId, sender, bookId, MessageType.Photo,
            mediaUrl: mediaUrl, clientId: clientId, parentMessageId: parentMessageId, clientSentAt: sentAt);
        if (!alreadyBroadcast) await BroadcastAndNotify(bookId, dto, bookTitle, senderDeviceToken);
        return dto;
    }

    // The app's own post of a video, after its upload: every client before 2.2 design v2, and a
    // current one that's running when its upload finishes (it needn't wait for storage's report).
    public async Task<MessageDto> SendVideoAsync(Guid userId, SenderContext sender, Guid bookId, string mediaUrl,
        Guid? clientId, Guid? parentMessageId, string? senderDeviceToken, DateTime? sentAt = null)
    {
        if (!IsOwnBlobUrl(mediaUrl)) throw new MessageSendException("Invalid media URL.");
        if (await TryRebroadcastExistingAsync(bookId, userId, clientId) is { } existing) return existing;
        // A reserved video was counted against the limit when it was reserved.
        var reserved = clientId is Guid cid && await db.PendingVideos.AnyAsync(p => p.SenderId == userId && p.ClientId == cid);
        if (!reserved) EnforceRateLimit(userId);
        return await CreateVideoAsync(userId, sender, bookId, mediaUrl, clientId, parentMessageId, senderDeviceToken, sentAt);
    }

    private async Task<MessageDto> CreateVideoAsync(Guid userId, SenderContext sender, Guid bookId, string mediaUrl,
        Guid? clientId, Guid? parentMessageId, string? senderDeviceToken, DateTime? sentAt)
    {
        await EnforceBlobSizeAsync(mediaUrl, MaxVideoBytes, "Video");

        var (dto, bookTitle, alreadyBroadcast) = await SaveMessageAsync(userId, sender, bookId, MessageType.Video,
            mediaUrl: mediaUrl, clientId: clientId, parentMessageId: parentMessageId, clientSentAt: sentAt);
        if (!alreadyBroadcast) await BroadcastAndNotify(bookId, dto, bookTitle, senderDeviceToken);
        if (clientId is Guid id)
            await db.PendingVideos.Where(p => p.SenderId == userId && p.ClientId == id).ExecuteDeleteAsync();
        return dto;
    }

    /// #204 design v2 — how long a video's upload link lasts: as long as the send token that
    /// reserved it, less a margin (a user-delegation SAS can't outlive 7 days from its key).
    public static readonly TimeSpan VideoUploadLinkValidity = SendToken.Lifetime - TimeSpan.FromHours(1);

    /// A reservation nobody uploaded to — the phone was lost, the app deleted — is dropped after this.
    public static readonly TimeSpan PendingVideoMaxAge = SendToken.Lifetime + TimeSpan.FromDays(1);

    // #204 design v2 — the first half of a video send. The app calls this once the video is
    // compressed and gets a link to upload it straight to storage (too big to pass through App
    // Service, see SendMediaFileAsync). It then hands that one upload to iOS; when storage
    // reports the file landed, CompleteReservedVideoAsync creates the message. So once the upload
    // is handed over, nothing needs the app — the post the app used to make afterwards waited on
    // the app being awake, and a locked phone held it for minutes (2.2 (5)).
    //
    // Everything that can refuse a send is checked here, before a byte is uploaded. Calling it
    // again for the same send (same client id) reuses the reservation with a fresh link, and
    // counts once against the send limit.
    public async Task<VideoReservation> ReserveVideoAsync(Guid userId, SenderContext sender, Guid bookId, Guid clientId,
        Guid? parentMessageId, string? senderDeviceToken, DateTime? sentAt)
    {
        if (await TryRebroadcastExistingAsync(bookId, userId, clientId) is { } existing)
            return new VideoReservation(null, null, existing);

        var pending = await db.PendingVideos.FirstOrDefaultAsync(p => p.SenderId == userId && p.ClientId == clientId);
        if (pending is null)
        {
            EnforceRateLimit(userId);
            var book = await ValidateSenderAndBookAsync(sender, bookId);
            var stale = time.GetUtcNow().UtcDateTime - PendingVideoMaxAge;
            await db.PendingVideos.Where(p => p.CreatedAt < stale).ExecuteDeleteAsync();

            pending = new PendingVideo
            {
                SenderId = userId,
                BookId = bookId,
                ClientId = clientId,
                MediaUrl = blob.NewMediaBlobUrl(book.ClubId, "mp4"),
                ParentMessageId = parentMessageId,
                DeviceId = senderDeviceToken,
                SentAt = sentAt,
                CreatedAt = time.GetUtcNow().UtcDateTime
            };
            db.PendingVideos.Add(pending);
            try
            {
                await db.SaveChangesAsync();
            }
            catch (DbUpdateException ex) when (IsUniqueClientIdViolation(ex))
            {
                // A concurrent reservation of the same send won: use its blob.
                db.Entry(pending).State = EntityState.Detached;
                pending = await db.PendingVideos.SingleAsync(p => p.SenderId == userId && p.ClientId == clientId);
            }
        }
        else
        {
            await ValidateSenderAndBookAsync(sender, pending.BookId);
        }

        var uploadUrl = await blob.GenerateVideoUploadUrlAsync(pending.MediaUrl, VideoUploadLinkValidity);
        return new VideoReservation(uploadUrl, pending.MediaUrl, null);
    }

    // #204 design v2 — the second half: storage reports a file landed (StorageEventsController).
    // If it's a reserved video, create its message now, exactly as the sender's own post would —
    // tap time, reply, the sender's device skipped for push. Anything else is ignored: a voice or
    // photo file, an older client's video, a video whose message already exists (the app's own
    // post got there first, which removed the reservation).
    //
    // The report isn't trusted: the file must really be in storage. A refusal (too large, no
    // longer a member) has nobody to tell here; the app hears the same refusal, with its reason,
    // when it posts the video itself. True when a reservation was settled.
    public async Task<bool> CompleteReservedVideoAsync(string blobUrl)
    {
        var plainUrl = blobUrl.Split('?')[0];
        var pending = await db.PendingVideos.AsNoTracking().FirstOrDefaultAsync(p => p.MediaUrl == plainUrl);
        if (pending is null) return false;
        if (!await blob.BlobExistsAsync(plainUrl)) return false;

        try
        {
            var sender = await LoadSenderContextAsync(pending.SenderId);
            await CreateVideoAsync(pending.SenderId, sender, pending.BookId, pending.MediaUrl, pending.ClientId,
                pending.ParentMessageId, pending.DeviceId, pending.SentAt);
        }
        catch (MessageSendException)
        {
            await db.PendingVideos.Where(p => p.Id == pending.Id).ExecuteDeleteAsync();
        }
        return true;
    }

    // #204 — one request per voice/photo message: the file's bytes ARE the request body, and the
    // server stores them and creates the message. The 3-step path (upload link → blob PUT → post
    // with media_url) needs the app awake to start steps 1 and 3, which is exactly when a locked
    // or offline phone stalls; one request can be handed to iOS's background transfer at tap time
    // and finished by iOS alone. Video stays on the 3-step path: up to 100 MB is too much to push
    // through App Service, whose front end cuts requests off at ~230 s.
    //
    // Order matters, and every check is BEFORE the bytes are stored, so a refused send leaves
    // nothing behind: dedup (a re-send returns the message without reading the body), then the
    // rate limit, then who/where, then size.
    public static MessageType? MediaFileTypeFor(string? contentType) =>
        contentType?.Split(';')[0].Trim().ToLowerInvariant() switch
        {
            "audio/mp4" => MessageType.Voice,
            "image/jpeg" => MessageType.Photo,
            _ => null
        };

    public async Task<MessageDto> SendMediaFileAsync(Guid userId, SenderContext sender, Guid bookId,
        string? contentType, long? contentLength, Stream content, int? durationSeconds,
        Guid clientId, Guid? parentMessageId, string? senderDeviceToken, CancellationToken ct, DateTime? sentAt = null)
    {
        var type = MediaFileTypeFor(contentType)
            ?? throw new MessageSendException("Only voice (audio/mp4) and photo (image/jpeg) files can be sent this way.");
        if (await TryRebroadcastExistingAsync(bookId, userId, clientId) is { } existing) return existing;
        EnforceRateLimit(userId);
        var book = await ValidateSenderAndBookAsync(sender, bookId);

        var (maxBytes, label, ext) = type == MessageType.Voice
            ? (MaxVoiceBytes, "Voice message", "m4a")
            : (MaxPhotoBytes, "Photo", "jpg");
        var tooLarge = $"{label} is too large (max {maxBytes / (1024 * 1024)} MB).";
        if (contentLength is > 0 && contentLength > maxBytes) throw new MessageSendException(tooLarge);
        if (contentLength == 0) throw new MessageSendException($"{label} is empty.");

        string mediaUrl;
        try
        {
            // Capped as it streams, not only by Content-Length — a chunked body declares no length.
            mediaUrl = await blob.UploadMediaAsync(book.ClubId, ext, new CappedReadStream(content, maxBytes),
                contentType!.Split(';')[0].Trim(), ct);
        }
        catch (Exception ex) when (CappedReadStream.WasExceeded(ex))
        {
            throw new MessageSendException(tooLarge);
        }

        var (dto, bookTitle, alreadyBroadcast) = await SaveMessageAsync(userId, sender, bookId, type,
            mediaUrl: mediaUrl, durationSeconds: type == MessageType.Voice ? durationSeconds ?? 0 : null,
            clientId: clientId, parentMessageId: parentMessageId, clientSentAt: sentAt);
        if (alreadyBroadcast)
        {
            // Lost a same-clientId race to a concurrent copy of this send, which stored its own
            // file: this one is an orphan nothing will ever reference.
            await blob.DeleteMediaAsync(mediaUrl);
            return dto;
        }
        await BroadcastAndNotify(bookId, dto, bookTitle, senderDeviceToken);
        return dto;
    }

    // #204 — `clientId` is new: the hub's ForwardMessage (2.1 and older) passes null and behaves
    // exactly as before; the REST forward (2.2) passes one, so a retried forward is deduped like
    // any other send instead of posting the message twice.
    public async Task<MessageDto> ForwardAsync(Guid userId, SenderContext sender, Guid bookId, Guid messageId,
        string? senderDeviceToken, Guid? clientId = null, DateTime? sentAt = null)
    {
        if (await TryRebroadcastExistingAsync(bookId, userId, clientId) is { } existing) return existing;
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
            body: original.Body, mediaUrl: plainMediaUrl, durationSeconds: original.DurationSeconds, isForwarded: true,
            clientId: clientId, clientSentAt: sentAt);
        // True only when a concurrent forward with the same clientId won the insert race.
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

    // Who may send where. Runs inside SaveMessageAsync for every send, and also up front in the
    // file-body send so a refused send never stores its bytes (FindAsync's second call for the
    // same book is served from the change tracker, not the database).
    private async Task<Book> ValidateSenderAndBookAsync(SenderContext sender, Guid bookId)
    {
        if (!sender.IsApproved) throw new MessageSendException("Account not approved.");
        var book = await db.Books.FindAsync(bookId) ?? throw new MessageSendException("Book not found");
        if (!sender.ClubIds.Contains(book.ClubId)) throw new MessageSendException("Not a member of this club.");
        return book;
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
        Guid? clientId = null, Guid? parentMessageId = null, DateTime? clientSentAt = null)
    {
        var book = await ValidateSenderAndBookAsync(sender, bookId);
        var receivedAt = time.GetUtcNow().UtcDateTime;

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
            ParentMessageId = parentMessageId,
            ReceivedAt = receivedAt,
            SentAt = ClampSentAt(clientSentAt, receivedAt)
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
            deleted ? null : m.Transcript,
            ReceivedAt: m.ReceivedAt);
    }
}
