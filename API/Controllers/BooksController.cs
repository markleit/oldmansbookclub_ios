using BookClubApi.Data;
using BookClubApi.Models;
using BookClubApi.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;

namespace BookClubApi.Controllers;

[Authorize]
[ApiController]
[Route("[controller]")]
public class BooksController(AppDbContext db, BlobService blob, IConfiguration config, IHttpClientFactory http, ILogger<BooksController> logger) : ControllerBase
{
    private Guid UserId => Guid.Parse(User.FindFirst("sub")!.Value);

    [HttpGet]
    public async Task<IEnumerable<BookDto>> GetMyBooks()
    {
        var myClubIds = await db.Memberships
            .Where(m => m.UserId == UserId)
            .Select(m => m.ClubId)
            .ToListAsync();

        return await db.Books
            .Where(b => myClubIds.Contains(b.ClubId))
            .OrderBy(b => b.Status == "current" ? 0 : b.Status == "future" ? 1 : 2)
            .ThenByDescending(b => b.AddedAt)
            .Select(b => new BookDto(b.Id, b.ClubId, b.Title, b.Author, b.CoverBlobUrl, b.AddedAt, b.FinishedAt, b.Status))
            .ToListAsync();
    }

    [HttpGet("search")]
    public async Task<IEnumerable<BookSearchResult>> SearchBooks([FromQuery] string q)
    {
        if (string.IsNullOrWhiteSpace(q)) return [];

        var apiKey = config["GoogleBooks:ApiKey"];
        logger.LogInformation("Book search: q={Q} hasApiKey={HasKey}", q, !string.IsNullOrEmpty(apiKey));

        var url = $"https://www.googleapis.com/books/v1/volumes?q=intitle:{Uri.EscapeDataString(q)}&maxResults=5&printType=books";
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

        if (!json.TryGetProperty("items", out var items))
        {
            logger.LogInformation("Google Books returned no items for q={Q}", q);
            return [];
        }

        return items.EnumerateArray().Select(item =>
        {
            var info = item.GetProperty("volumeInfo");
            var title = info.TryGetProperty("title", out var t) ? t.GetString() ?? "" : "";
            var author = info.TryGetProperty("authors", out var a) && a.GetArrayLength() > 0
                ? a[0].GetString() ?? "" : "";
            string? coverUrl = null;
            if (info.TryGetProperty("imageLinks", out var links) &&
                links.TryGetProperty("thumbnail", out var thumb))
                coverUrl = thumb.GetString()?.Replace("http://", "https://");
            return new BookSearchResult(title, author, coverUrl);
        }).ToList();
    }

    [HttpPost]
    public async Task<ActionResult<BookDto>> CreateBook([FromBody] CreateBookRequest request)
    {
        var isMember = await db.Memberships
            .AnyAsync(m => m.UserId == UserId && m.ClubId == request.ClubId);
        if (!isMember) return Forbid();

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
            new BookDto(book.Id, book.ClubId, book.Title, book.Author, book.CoverBlobUrl, book.AddedAt, book.FinishedAt, book.Status));
    }

    [HttpDelete("{bookId}")]
    public async Task<IActionResult> DeleteBook(Guid bookId)
    {
        var book = await db.Books.FindAsync(bookId);
        if (book is null) return NotFound();

        var isMember = await db.Memberships
            .AnyAsync(m => m.UserId == UserId && m.ClubId == book.ClubId);
        if (!isMember) return Forbid();

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

        var isMember = await db.Memberships
            .AnyAsync(m => m.UserId == UserId && m.ClubId == book.ClubId);
        if (!isMember) return Forbid();

        book.Status = request.Status;
        book.FinishedAt = request.Status == "past" ? DateTime.UtcNow : null;
        await db.SaveChangesAsync();
        return Ok();
    }

    [HttpGet("{bookId}/messages")]
    public async Task<ActionResult<IEnumerable<MessageDto>>> GetMessages(
        Guid bookId, [FromQuery] DateTime? before, [FromQuery] int limit = 50)
    {
        var book = await db.Books.FindAsync(bookId);
        if (book is null) return NotFound();

        var isMember = await db.Memberships
            .AnyAsync(m => m.UserId == UserId && m.ClubId == book.ClubId);
        if (!isMember) return Forbid();

        var query = db.Messages.Where(m => m.BookId == bookId);

        if (before.HasValue)
            query = query.Where(m => m.SentAt < before.Value);

        var messages = await query
            .OrderByDescending(m => m.SentAt)
            .Take(limit)
            .Select(m => new MessageDto(
                m.Id, m.ClubId, m.SenderId,
                m.DeletedAt == null ? (m.Sender.Nickname ?? m.Sender.DisplayName) : "",
                m.DeletedAt == null ? m.Sender.AvatarUrl : null,
                m.Type,
                m.DeletedAt == null ? m.Body : null,
                m.DeletedAt == null ? m.MediaUrl : null,
                m.DeletedAt == null ? m.DurationSeconds : null,
                m.SentAt,
                m.DeletedAt != null,
                m.IsForwarded))
            .ToListAsync();

        if (messages.Any(m => m.MediaUrl != null))
        {
            var (key, keyExpiry) = await blob.GetReadDelegationKeyAsync();
            messages = messages.Select(m => m.MediaUrl != null
                ? m with { MediaUrl = blob.GenerateFreshReadUrl(m.MediaUrl, key, keyExpiry) }
                : m).ToList();
        }

        return messages;
    }

    [HttpPost("{bookId}/read")]
    public async Task<IActionResult> MarkRead(Guid bookId, [FromBody] Guid messageId)
    {
        var book = await db.Books.FindAsync(bookId);
        if (book is null) return NotFound();

        var isMember = await db.Memberships
            .AnyAsync(m => m.UserId == UserId && m.ClubId == book.ClubId);
        if (!isMember) return Forbid();

        var existing = await db.ChatReads
            .FirstOrDefaultAsync(cr => cr.UserId == UserId && cr.BookId == bookId);

        if (existing is null)
        {
            db.ChatReads.Add(new ChatRead { UserId = UserId, BookId = bookId, LastSeenMessageId = messageId });
        }
        else
        {
            existing.LastSeenMessageId = messageId;
            existing.UpdatedAt = DateTime.UtcNow;
        }

        await db.SaveChangesAsync();
        return Ok();
    }

    [HttpGet("{bookId}/reads")]
    public async Task<ActionResult<List<ChatReadDto>>> GetReads(Guid bookId)
    {
        var book = await db.Books.FindAsync(bookId);
        if (book is null) return NotFound();

        var isMember = await db.Memberships
            .AnyAsync(m => m.UserId == UserId && m.ClubId == book.ClubId);
        if (!isMember) return Forbid();

        var reads = await db.ChatReads
            .Where(cr => cr.BookId == bookId && cr.UserId != UserId && cr.LastSeenMessageId != null)
            .Select(cr => new ChatReadDto(cr.UserId, cr.User.Nickname ?? cr.User.DisplayName, cr.User.AvatarUrl, cr.LastSeenMessageId!.Value))
            .ToListAsync();

        return reads;
    }
}
