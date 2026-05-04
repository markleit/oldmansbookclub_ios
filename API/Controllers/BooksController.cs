using BookClubApi.Data;
using BookClubApi.Models;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;

namespace BookClubApi.Controllers;

[Authorize]
[ApiController]
[Route("[controller]")]
public class BooksController(AppDbContext db) : ControllerBase
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
            .OrderByDescending(b => b.FinishedAt == null) // current reads first
            .ThenByDescending(b => b.AddedAt)
            .Select(b => new BookDto(b.Id, b.ClubId, b.Title, b.Author, b.CoverBlobUrl, b.AddedAt, b.FinishedAt))
            .ToListAsync();
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
            CoverBlobUrl = request.CoverUrl
        };

        db.Books.Add(book);
        await db.SaveChangesAsync();

        return CreatedAtAction(nameof(GetMyBooks),
            new BookDto(book.Id, book.ClubId, book.Title, book.Author, book.CoverBlobUrl, book.AddedAt, book.FinishedAt));
    }

    [HttpDelete("{bookId}")]
    public async Task<IActionResult> DeleteBook(Guid bookId)
    {
        var book = await db.Books.FindAsync(bookId);
        if (book is null) return NotFound();

        var isMember = await db.Memberships
            .AnyAsync(m => m.UserId == UserId && m.ClubId == book.ClubId);
        if (!isMember) return Forbid();

        db.Books.Remove(book);
        await db.SaveChangesAsync();
        return NoContent();
    }

    [HttpPost("{bookId}/finish")]
    public async Task<IActionResult> FinishBook(Guid bookId)
    {
        var book = await db.Books.FindAsync(bookId);
        if (book is null) return NotFound();

        var isMember = await db.Memberships
            .AnyAsync(m => m.UserId == UserId && m.ClubId == book.ClubId);
        if (!isMember) return Forbid();

        book.FinishedAt = DateTime.UtcNow;
        await db.SaveChangesAsync();
        return Ok();
    }

    [HttpGet("{bookId}/messages")]
    public async Task<IEnumerable<MessageDto>> GetMessages(
        Guid bookId, [FromQuery] DateTime? before, [FromQuery] int limit = 50)
    {
        var book = await db.Books.FindAsync(bookId);
        if (book is null) return [];

        var isMember = await db.Memberships
            .AnyAsync(m => m.UserId == UserId && m.ClubId == book.ClubId);
        if (!isMember) return [];

        var query = db.Messages
            .Where(m => m.BookId == bookId && m.DeletedAt == null);

        if (before.HasValue)
            query = query.Where(m => m.SentAt < before.Value);

        return await query
            .OrderByDescending(m => m.SentAt)
            .Take(limit)
            .Select(m => new MessageDto(
                m.Id, m.ClubId, m.SenderId, m.Sender.DisplayName,
                m.Type, m.Body, m.MediaUrl, m.DurationSeconds, m.SentAt))
            .ToListAsync();
    }
}
