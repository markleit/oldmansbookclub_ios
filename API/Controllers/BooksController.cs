using BookClubApi.Data;
using BookClubApi.Hubs;
using BookClubApi.Models;
using BookClubApi.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.SignalR;
using Microsoft.EntityFrameworkCore;

namespace BookClubApi.Controllers;

[Authorize]
[ApiController]
[Route("[controller]")]
public class BooksController(AppDbContext db, BlobService blob, IConfiguration config, IHttpClientFactory http, ILogger<BooksController> logger, IHubContext<ChatHub> hub) : ControllerBase
{
    private Guid UserId => Guid.Parse(User.FindFirst("sub")!.Value);

    // Broadcast a read/heard receipt to everyone viewing the book so receipts update
    // live (no chat reload). Includes the reader's name/avatar so a client that hasn't
    // seen this reader yet can render them.
    private async Task BroadcastReadAsync(Guid bookId, Guid lastSeenMessageId)
    {
        var u = await db.Users.Where(x => x.Id == UserId)
            .Select(x => new { Name = x.Nickname ?? x.DisplayName, x.AvatarUrl, x.AvatarUpdatedAt }).FirstOrDefaultAsync();
        var avatarUrl = u?.AvatarUrl is not null ? await blob.GenerateAvatarReadUrlAsync(UserId, u.AvatarUpdatedAt) : null;
        await hub.Clients.Group(bookId.ToString()).SendAsync("ReadReceipt", new
        {
            bookId, userId = UserId, displayName = u?.Name ?? "", avatarUrl, lastSeenMessageId
        });
    }

    private async Task BroadcastHeardAsync(Guid bookId, List<Guid> messageIds)
    {
        if (messageIds.Count == 0) return;
        var u = await db.Users.Where(x => x.Id == UserId)
            .Select(x => new { Name = x.Nickname ?? x.DisplayName, x.AvatarUrl, x.AvatarUpdatedAt }).FirstOrDefaultAsync();
        var avatarUrl = u?.AvatarUrl is not null ? await blob.GenerateAvatarReadUrlAsync(UserId, u.AvatarUpdatedAt) : null;
        await hub.Clients.Group(bookId.ToString()).SendAsync("HeardReceipt", new
        {
            bookId, userId = UserId, displayName = u?.Name ?? "", avatarUrl, messageIds
        });
    }

    [HttpGet]
    public async Task<IEnumerable<BookDto>> GetMyBooks()
    {
        var myClubIds = await db.Memberships
            .Where(m => m.UserId == UserId)
            .Select(m => m.ClubId)
            .ToListAsync();

        var books = await db.Books
            .Where(b => myClubIds.Contains(b.ClubId))
            .OrderBy(b => b.Status == "current" ? 0 : b.Status == "future" ? 1 : 2)
            .ThenByDescending(b => b.AddedAt)
            .ToListAsync();

        var unread = await ComputeUnreadCountsAsync(books.Select(b => b.Id).ToList());

        return books.Select(b => new BookDto(b.Id, b.ClubId, b.Title, b.Author, b.CoverBlobUrl, b.AddedAt, b.FinishedAt, b.Status, b.Description, b.PublishedYear, b.PageCount, unread.GetValueOrDefault(b.Id)));
    }

    private Task<Dictionary<Guid, int>> ComputeUnreadCountsAsync(List<Guid> bookIds)
        => UnreadCalculator.PerBookAsync(db, UserId, bookIds);

    // The caller's unread count for one book, as the server computes it. Every endpoint that
    // consumes messages returns this so the client never has to re-derive the number itself
    // (#119) — it applies an optimistic change for instant feedback and this corrects it.
    private async Task<int> UnreadCountAsync(Guid bookId)
        => (await UnreadCalculator.PerBookAsync(db, UserId, [bookId])).GetValueOrDefault(bookId);

    private async Task<IActionResult> OkWithUnreadAsync(Guid bookId)
        => Ok(new { unreadCount = await UnreadCountAsync(bookId) });

    // Mark a single voice message heard (on full playback or per-message "mark as heard").
    // Sticky/idempotent — replays never remove it.
    [HttpPost("{bookId}/messages/{messageId}/heard")]
    public async Task<IActionResult> MarkHeard(Guid bookId, Guid messageId)
    {
        var book = await db.Books.FindAsync(bookId);
        if (book is null) return NotFound();
        if (!await db.Memberships.AnyAsync(m => m.UserId == UserId && m.ClubId == book.ClubId)) return Forbid();

        if (!await db.MessageHeards.AnyAsync(h => h.UserId == UserId && h.MessageId == messageId))
        {
            db.MessageHeards.Add(new MessageHeard { UserId = UserId, MessageId = messageId });
            try { await db.SaveChangesAsync(); }
            catch (DbUpdateException) { /* raced another mark — already heard, fine */ }
        }
        await BroadcastHeardAsync(bookId, [messageId]);
        return await OkWithUnreadAsync(bookId);
    }

    // Mark every (others') voice message in a book heard — backs "Mark all as heard".
    [HttpPost("{bookId}/heard/all")]
    public async Task<IActionResult> MarkAllHeard(Guid bookId)
    {
        var book = await db.Books.FindAsync(bookId);
        if (book is null) return NotFound();
        if (!await db.Memberships.AnyAsync(m => m.UserId == UserId && m.ClubId == book.ClubId)) return Forbid();

        var alreadyHeard = db.MessageHeards.Where(h => h.UserId == UserId).Select(h => h.MessageId);
        var toMark = await db.Messages
            .Where(m => m.BookId == bookId && m.Type == MessageType.Voice && m.SenderId != UserId
                && m.DeletedAt == null && !alreadyHeard.Contains(m.Id))
            .Select(m => m.Id)
            .ToListAsync();

        foreach (var id in toMark) db.MessageHeards.Add(new MessageHeard { UserId = UserId, MessageId = id });
        if (toMark.Count > 0) await db.SaveChangesAsync();
        await BroadcastHeardAsync(bookId, toMark);
        return await OkWithUnreadAsync(bookId);
    }

    // Mark a specific set of voice messages heard (#119). Backs the client's two-way heard
    // reconcile: the device pushes up anything it has marked heard locally that the server is
    // missing (a markHeard POST that never landed). Unlike /heard/all this touches only the ids
    // given, so it can repair drift without silently consuming messages the user never played.
    // Ids that aren't others' live voice messages in this book are ignored, not rejected.
    [HttpPost("{bookId}/heard")]
    public async Task<IActionResult> MarkHeardBatch(Guid bookId, [FromBody] List<Guid> messageIds)
    {
        var book = await db.Books.FindAsync(bookId);
        if (book is null) return NotFound();
        if (!await db.Memberships.AnyAsync(m => m.UserId == UserId && m.ClubId == book.ClubId)) return Forbid();
        if (messageIds is null || messageIds.Count == 0)
            return Ok(new { unreadCount = await UnreadCountAsync(bookId), heard = Array.Empty<Guid>() });

        // Everything the caller asked about that this endpoint could ever accept: others' live
        // voice messages in this book. Anything else — your own message, a deleted one, an id
        // from another book — is not a transient failure, it will never be accepted, and the
        // reply says so explicitly so the client can stop asking (#119).
        var acceptable = await db.Messages
            .Where(m => m.BookId == bookId && m.Type == MessageType.Voice && m.SenderId != UserId
                && m.DeletedAt == null && messageIds.Contains(m.Id))
            .Select(m => m.Id)
            .ToListAsync();

        var alreadyHeard = await db.MessageHeards
            .Where(h => h.UserId == UserId && acceptable.Contains(h.MessageId))
            .Select(h => h.MessageId)
            .ToListAsync();

        var toMark = acceptable.Except(alreadyHeard).ToList();
        if (toMark.Count > 0)
        {
            foreach (var id in toMark) db.MessageHeards.Add(new MessageHeard { UserId = UserId, MessageId = id });
            try { await db.SaveChangesAsync(); }
            catch (DbUpdateException) { /* raced a concurrent mark — the rows exist either way */ }
            await BroadcastHeardAsync(bookId, toMark);
        }

        // `heard` is every requested id that is now heard, not just the ones written here, so a
        // replay of an already-applied batch still confirms rather than looking like a refusal.
        return Ok(new { unreadCount = await UnreadCountAsync(bookId), heard = acceptable });
    }

    // The caller's OWN heard voice-message IDs for a book. The /reads endpoint deliberately
    // excludes self (it powers "read by others"), so this exposes the caller's heard state.
    // The client seeds its local heard cache (PlaybackProgressStore) from this on load, so
    // heard/unread state is per-account and consistent across devices (#102).
    [HttpGet("{bookId}/my-heard")]
    public async Task<ActionResult<List<Guid>>> MyHeardMessageIds(Guid bookId)
    {
        var book = await db.Books.FindAsync(bookId);
        if (book is null) return NotFound();
        if (!await db.Memberships.AnyAsync(m => m.UserId == UserId && m.ClubId == book.ClubId)) return Forbid();

        return await db.Messages
            .Where(m => m.BookId == bookId && m.Type == MessageType.Voice
                && db.MessageHeards.Any(h => h.UserId == UserId && h.MessageId == m.Id))
            .Select(m => m.Id)
            .ToListAsync();
    }

    [HttpGet("search")]
    public async Task<IEnumerable<BookSearchResult>> SearchBooks([FromQuery] string q)
    {
        if (string.IsNullOrWhiteSpace(q)) return [];
        var volumes = await FetchGoogleBooksAsync(q);
        return volumes.Select(v => new BookSearchResult(v.Title, v.Author, v.CoverUrl)).ToList();
    }

    // A parsed Google Books volume with the fields we care about.
    private record GoogleVolume(string Title, string Author, string? CoverUrl, string? Description, int? PublishedYear, int? PageCount);

    // Shared Google Books fetch + parse, used by both search and the lazy metadata
    // enrichment. Returns [] on any failure (caller degrades gracefully).
    private async Task<List<GoogleVolume>> FetchGoogleBooksAsync(string q)
    {
        var apiKey = config["GoogleBooks:ApiKey"];
        var url = $"https://www.googleapis.com/books/v1/volumes?q=intitle:{Uri.EscapeDataString(q)}&maxResults=20&printType=books";
        if (!string.IsNullOrEmpty(apiKey)) url += $"&key={apiKey}";

        var client = http.CreateClient();
        HttpResponseMessage response;
        try { response = await client.GetAsync(url); }
        catch (Exception ex)
        {
            logger.LogError(ex, "Google Books HTTP request failed");
            return [];
        }

        if (!response.IsSuccessStatusCode)
        {
            var body = await response.Content.ReadAsStringAsync();
            logger.LogWarning("Google Books returned {Status}: {Body}", (int)response.StatusCode, body[..Math.Min(500, body.Length)]);
            return [];
        }

        var json = await response.Content.ReadFromJsonAsync<System.Text.Json.JsonElement>();
        if (!json.TryGetProperty("items", out var items)) return [];

        return items.EnumerateArray().Select(item =>
        {
            var info = item.GetProperty("volumeInfo");
            var title = info.TryGetProperty("title", out var t) ? t.GetString() ?? "" : "";
            var author = info.TryGetProperty("authors", out var a) && a.GetArrayLength() > 0
                ? a[0].GetString() ?? "" : "";
            string? coverUrl = null;
            if (info.TryGetProperty("imageLinks", out var links) &&
                links.TryGetProperty("thumbnail", out var thumb))
                coverUrl = EnlargeCover(thumb.GetString());
            var description = info.TryGetProperty("description", out var d) ? d.GetString() : null;
            int? year = info.TryGetProperty("publishedDate", out var pd) ? ParseYear(pd.GetString()) : null;
            int? pages = info.TryGetProperty("pageCount", out var pc) && pc.TryGetInt32(out var p) ? p : null;
            return new GoogleVolume(title, author, coverUrl, description, year, pages);
        }).ToList();
    }

    // Normalize a Google Books thumbnail URL to https (required by ATS). NOTE: do not
    // rewrite zoom/edge here — Google doesn't reliably serve the rewritten variants,
    // which blanks the preview image. A genuinely larger cover needs a per-volume fetch.
    private static string? EnlargeCover(string? url)
        => string.IsNullOrEmpty(url) ? null : url.Replace("http://", "https://");

    // Google publishedDate is "2005", "2005-03", or "2005-03-01" — take the year.
    private static int? ParseYear(string? date)
    {
        if (date is { Length: >= 4 } && int.TryParse(date[..4], out var y)) return y;
        return null;
    }

    [HttpPost]
    public async Task<ActionResult<BookDto>> CreateBook([FromBody] CreateBookRequest request)
    {
        var isClubAdmin = await db.Memberships
            .AnyAsync(m => m.UserId == UserId && m.ClubId == request.ClubId && m.IsClubAdmin);
        if (!isClubAdmin) return Forbid();

        var book = new Book
        {
            ClubId = request.ClubId,
            Title = request.Title,
            Author = request.Author,
            CoverBlobUrl = request.CoverUrl,
            Status = "future"
        };

        db.Books.Add(book);
        await db.SaveChangesAsync();

        return CreatedAtAction(nameof(GetMyBooks),
            new BookDto(book.Id, book.ClubId, book.Title, book.Author, book.CoverBlobUrl, book.AddedAt, book.FinishedAt, book.Status, book.Description, book.PublishedYear, book.PageCount));
    }

    // Book details. Lazily backfills metadata (description / published year / page
    // count, and upgrades the cover) from Google Books the first time a book without
    // it is viewed, so existing books fill in on demand with no user action.
    [HttpGet("{bookId}")]
    public async Task<ActionResult<BookDto>> GetBook(Guid bookId)
    {
        var book = await db.Books.FindAsync(bookId);
        if (book is null) return NotFound();

        var isMember = await db.Memberships.AnyAsync(m => m.UserId == UserId && m.ClubId == book.ClubId);
        if (!isMember) return Forbid();

        if (book.MetadataFetchedAt is null)
        {
            var match = (await FetchGoogleBooksAsync(book.Title)).FirstOrDefault();
            if (match is not null)
            {
                book.Description ??= match.Description;
                book.PublishedYear ??= match.PublishedYear;
                book.PageCount ??= match.PageCount;
                if (!string.IsNullOrEmpty(match.CoverUrl)) book.CoverBlobUrl = match.CoverUrl;
            }
            book.MetadataFetchedAt = DateTime.UtcNow;   // mark attempted, even if no match
            await db.SaveChangesAsync();
        }

        return new BookDto(book.Id, book.ClubId, book.Title, book.Author, book.CoverBlobUrl, book.AddedAt, book.FinishedAt, book.Status, book.Description, book.PublishedYear, book.PageCount);
    }

    // Edit a book's title/author (backs the "Edit Book" action). Club-admin only, like
    // create/delete. Cover + metadata are left untouched.
    [HttpPatch("{bookId}")]
    public async Task<ActionResult<BookDto>> UpdateBook(Guid bookId, [FromBody] UpdateBookRequest request)
    {
        var book = await db.Books.FindAsync(bookId);
        if (book is null) return NotFound();

        var isClubAdmin = await db.Memberships
            .AnyAsync(m => m.UserId == UserId && m.ClubId == book.ClubId && m.IsClubAdmin);
        if (!isClubAdmin) return Forbid();

        var title = request.Title?.Trim();
        if (string.IsNullOrEmpty(title)) return BadRequest("Title is required.");
        book.Title = title;
        book.Author = request.Author?.Trim() ?? "";
        await db.SaveChangesAsync();

        return new BookDto(book.Id, book.ClubId, book.Title, book.Author, book.CoverBlobUrl, book.AddedAt, book.FinishedAt, book.Status, book.Description, book.PublishedYear, book.PageCount);
    }

    [HttpDelete("{bookId}")]
    public async Task<IActionResult> DeleteBook(Guid bookId)
    {
        var book = await db.Books.FindAsync(bookId);
        if (book is null) return NotFound();

        var isClubAdmin = await db.Memberships
            .AnyAsync(m => m.UserId == UserId && m.ClubId == book.ClubId && m.IsClubAdmin);
        if (!isClubAdmin) return Forbid();

        await db.Messages.Where(m => m.BookId == bookId).ExecuteDeleteAsync();
        db.Books.Remove(book);
        await db.SaveChangesAsync();
        return NoContent();
    }

    [HttpPatch("{bookId}/status")]
    public async Task<IActionResult> SetStatus(Guid bookId, [FromBody] SetBookStatusRequest request)
    {
        if (request.Status is not ("future" or "current" or "past"))
            return BadRequest("Status must be 'future', 'current', or 'past'.");

        var book = await db.Books.FindAsync(bookId);
        if (book is null) return NotFound();

        var isClubAdmin = await db.Memberships
            .AnyAsync(m => m.UserId == UserId && m.ClubId == book.ClubId && m.IsClubAdmin);
        if (!isClubAdmin) return Forbid();

        book.Status = request.Status;
        book.FinishedAt = request.Status == "past" ? DateTime.UtcNow : null;
        await db.SaveChangesAsync();
        return Ok();
    }

    [HttpGet("{bookId}/messages")]
    public async Task<ActionResult<IEnumerable<MessageDto>>> GetMessages(
        Guid bookId, [FromQuery] DateTime? before, [FromQuery] int limit = 50)
    {
        var access = await db.Books
            .Where(b => b.Id == bookId)
            .Select(b => new { b.ClubId, IsMember = b.Club.Memberships.Any(m => m.UserId == UserId) })
            .FirstOrDefaultAsync();

        if (access is null) return NotFound();
        if (!access.IsMember) return Forbid();

        var query = db.Messages.Where(m => m.BookId == bookId);

        if (before.HasValue)
            query = query.Where(m => m.SentAt < before.Value);

        var messages = await query
            .OrderByDescending(m => m.SentAt)
            .Take(limit)
            .Select(m => new MessageDto(
                m.Id, m.ClubId,
                m.DeletedAt == null ? m.SenderId : Guid.Empty,
                m.DeletedAt == null ? (m.Sender.Nickname ?? m.Sender.DisplayName) : "",
                m.DeletedAt == null ? m.Sender.AvatarUrl : null,
                m.Type,
                m.DeletedAt == null ? m.Body : null,
                m.DeletedAt == null ? m.MediaUrl : null,
                m.DeletedAt == null ? m.DurationSeconds : null,
                m.SentAt,
                m.DeletedAt != null,
                m.IsForwarded,
                m.DeletedAt == null ? m.ClientId : null,
                m.DeletedAt == null ? m.ParentMessageId : null,
                m.DeletedAt != null || m.Parent == null ? null
                    : (m.Parent.DeletedAt != null ? null : (m.Parent.Sender.Nickname ?? m.Parent.Sender.DisplayName)),
                m.DeletedAt != null || m.Parent == null ? null
                    : (m.Parent.DeletedAt != null ? "Deleted message"
                        : m.Parent.Type == MessageType.Text ? (m.Parent.Body!.Length <= 120 ? m.Parent.Body : m.Parent.Body!.Substring(0, 120) + "…")
                        : m.Parent.Type == MessageType.Voice ? (m.Parent.Transcript == null ? "🎤 Voice message" : "🎤 " + (m.Parent.Transcript.Length <= 120 ? m.Parent.Transcript : m.Parent.Transcript.Substring(0, 120) + "…"))
                        : m.Parent.Type == MessageType.Photo ? "📷 Photo"
                        : "🎬 Video"),
                m.DeletedAt != null || m.Parent == null || m.Parent.DeletedAt != null ? (DateTime?)null : m.Parent.SentAt,
                m.DeletedAt == null ? m.Transcript : null))
            .ToListAsync();

        if (messages.Any(m => m.MediaUrl != null || m.SenderAvatarUrl != null))
        {
            try
            {
                var (key, keyExpiry) = await blob.GetReadDelegationKeyAsync();
                messages = messages.Select(m => m with
                {
                    MediaUrl = blob.GenerateFreshReadUrl(m.MediaUrl, key, keyExpiry),
                    SenderAvatarUrl = blob.GenerateFreshReadUrl(m.SenderAvatarUrl, key, keyExpiry)
                }).ToList();
            }
            catch (Exception ex)
            {
                // Delegation key unavailable (e.g. local dev without Storage Blob Delegator role).
                // Return messages with plain URLs — images/avatars won't render but chat history loads.
                logger.LogWarning(ex, "[GetMessages] could not get delegation key; serving plain URLs");
            }
        }

        // #47 — attach per-user reactions so the client can derive counts/"mine" and apply
        // live receipts against them.
        var msgIds = messages.Select(m => m.Id).ToList();
        var reactionRows = await db.MessageReactions
            .Where(r => msgIds.Contains(r.MessageId))
            .Select(r => new { r.MessageId, r.UserId, r.Emoji })
            .ToListAsync();
        if (reactionRows.Count > 0)
        {
            var byMsg = reactionRows
                .GroupBy(r => r.MessageId)
                .ToDictionary(g => g.Key, g => (IReadOnlyList<MessageReactionDto>)g
                    .Select(r => new MessageReactionDto(r.UserId, r.Emoji)).ToList());
            messages = messages
                .Select(m => byMsg.TryGetValue(m.Id, out var rs) ? m with { Reactions = rs } : m)
                .ToList();
        }

        return messages;
    }

    // #47 — set or switch the caller's reaction on a message (one per user per message),
    // then broadcast so everyone viewing the book updates live.
    [HttpPost("{bookId}/messages/{messageId}/reactions")]
    public async Task<IActionResult> SetReaction(Guid bookId, Guid messageId, [FromBody] SetReactionRequest req)
    {
        var emoji = (req.Emoji ?? "").Trim();
        if (emoji.Length == 0 || emoji.Length > 16) return BadRequest("Invalid emoji.");
        if (!await IsBookMemberAsync(bookId)) return Forbid();
        if (!await db.Messages.AnyAsync(m => m.Id == messageId && m.BookId == bookId && m.DeletedAt == null))
            return NotFound();

        var existing = await db.MessageReactions.FirstOrDefaultAsync(r => r.UserId == UserId && r.MessageId == messageId);
        if (existing is null)
            db.MessageReactions.Add(new MessageReaction { UserId = UserId, MessageId = messageId, Emoji = emoji });
        else
        {
            existing.Emoji = emoji;
            existing.ReactedAt = DateTime.UtcNow;
        }
        await db.SaveChangesAsync();
        await BroadcastReactionAsync(bookId, messageId, emoji);
        return NoContent();
    }

    // #47 — remove the caller's reaction from a message.
    [HttpDelete("{bookId}/messages/{messageId}/reactions")]
    public async Task<IActionResult> RemoveReaction(Guid bookId, Guid messageId)
    {
        if (!await IsBookMemberAsync(bookId)) return Forbid();
        var existing = await db.MessageReactions.FirstOrDefaultAsync(r => r.UserId == UserId && r.MessageId == messageId);
        if (existing is not null)
        {
            db.MessageReactions.Remove(existing);
            await db.SaveChangesAsync();
            await BroadcastReactionAsync(bookId, messageId, null);
        }
        return NoContent();
    }

    // #47 — who reacted with what on a message (backs the tap-to-see-who popup).
    [HttpGet("{bookId}/messages/{messageId}/reactions")]
    public async Task<ActionResult<IEnumerable<ReactionReactorDto>>> GetReactions(Guid bookId, Guid messageId)
    {
        if (!await IsBookMemberAsync(bookId)) return Forbid();
        return await db.MessageReactions
            .Where(r => r.MessageId == messageId)
            .OrderBy(r => r.ReactedAt)
            .Select(r => new ReactionReactorDto(r.UserId, r.User.Nickname ?? r.User.DisplayName, r.Emoji))
            .ToListAsync();
    }

    private Task<bool> IsBookMemberAsync(Guid bookId) =>
        db.Books.Where(b => b.Id == bookId).AnyAsync(b => b.Club.Memberships.Any(m => m.UserId == UserId));

    private async Task BroadcastReactionAsync(Guid bookId, Guid messageId, string? emoji)
    {
        var u = await db.Users.Where(x => x.Id == UserId)
            .Select(x => new { Name = x.Nickname ?? x.DisplayName }).FirstOrDefaultAsync();
        await hub.Clients.Group(bookId.ToString()).SendAsync("ReactionReceipt", new
        {
            bookId, messageId, userId = UserId, displayName = u?.Name ?? "", emoji
        });
    }

    [HttpPost("{bookId}/read")]
    public async Task<IActionResult> MarkRead(Guid bookId, [FromBody] Guid messageId)
    {
        var book = await db.Books.FindAsync(bookId);
        if (book is null) return NotFound();

        var isMember = await db.Memberships
            .AnyAsync(m => m.UserId == UserId && m.ClubId == book.ClubId);
        if (!isMember) return Forbid();

        // The marker may only ever advance (#119). It's a pointer, not a timestamp, so a client
        // working from a stale cache — or a race between the chat-open call and a live-receive
        // call — could otherwise rewind it and resurrect already-read messages.
        var incomingSentAt = await db.Messages
            .Where(m => m.Id == messageId && m.BookId == bookId)
            .Select(m => (DateTime?)m.SentAt)
            .FirstOrDefaultAsync();
        if (incomingSentAt is null) return await OkWithUnreadAsync(bookId);   // unknown message — ignore

        var existing = await db.ChatReads
            .FirstOrDefaultAsync(cr => cr.UserId == UserId && cr.BookId == bookId);

        if (existing is null)
        {
            db.ChatReads.Add(new ChatRead { UserId = UserId, BookId = bookId, LastSeenMessageId = messageId });
        }
        else
        {
            var currentSentAt = existing.LastSeenMessageId == null ? null
                : await db.Messages
                    .Where(m => m.Id == existing.LastSeenMessageId)
                    .Select(m => (DateTime?)m.SentAt)
                    .FirstOrDefaultAsync();
            // Already read at or past this message — nothing changed, so don't re-broadcast either.
            if (currentSentAt is not null && incomingSentAt <= currentSentAt) return await OkWithUnreadAsync(bookId);
            existing.LastSeenMessageId = messageId;
            existing.UpdatedAt = DateTime.UtcNow;
        }

        await db.SaveChangesAsync();
        await BroadcastReadAsync(bookId, messageId);
        return await OkWithUnreadAsync(bookId);
    }

    [HttpGet("{bookId}/reads")]
    public async Task<ActionResult<List<ChatReadDto>>> GetReads(Guid bookId)
    {
        var book = await db.Books.FindAsync(bookId);
        if (book is null) return NotFound();

        var isMember = await db.Memberships
            .AnyAsync(m => m.UserId == UserId && m.ClubId == book.ClubId);
        if (!isMember) return Forbid();

        var readers = await db.ChatReads
            .Where(cr => cr.BookId == bookId && cr.UserId != UserId && cr.LastSeenMessageId != null)
            .Select(cr => new { cr.UserId, Name = cr.User.Nickname ?? cr.User.DisplayName, cr.User.AvatarUrl, LastSeen = cr.LastSeenMessageId!.Value })
            .ToListAsync();

        // Each reader's heard voice messages in this book — voice receipts reflect
        // actual listening, not just opening the chat.
        var readerIds = readers.Select(r => r.UserId).ToList();
        var voiceIds = await db.Messages
            .Where(m => m.BookId == bookId && m.Type == MessageType.Voice)
            .Select(m => m.Id).ToListAsync();
        var heardByUser = (await db.MessageHeards
                .Where(h => readerIds.Contains(h.UserId) && voiceIds.Contains(h.MessageId))
                .Select(h => new { h.UserId, h.MessageId })
                .ToListAsync())
            .GroupBy(h => h.UserId)
            .ToDictionary(g => g.Key, g => g.Select(x => x.MessageId).ToList());

        if (readers.Any(r => r.AvatarUrl != null))
        {
            try
            {
                var (key, keyExpiry) = await blob.GetReadDelegationKeyAsync();
                readers = readers.Select(r => r.AvatarUrl != null
                    ? r with { AvatarUrl = blob.GenerateFreshReadUrl(r.AvatarUrl, key, keyExpiry) }
                    : r).ToList();
            }
            catch (Exception ex)
            {
                logger.LogWarning(ex, "[GetReads] could not get delegation key; serving plain URLs");
            }
        }

        return readers
            .Select(r => new ChatReadDto(r.UserId, r.Name, r.AvatarUrl, r.LastSeen, heardByUser.GetValueOrDefault(r.UserId, [])))
            .ToList();
    }
}
