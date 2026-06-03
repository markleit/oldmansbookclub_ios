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
public class MessagesController(AppDbContext db, BlobService blob, ILogger<MessagesController> logger) : ControllerBase
{
    private Guid UserId => Guid.Parse(User.FindFirst("sub")!.Value);

    [HttpGet("saved")]
    public async Task<IEnumerable<SavedMessageDto>> GetSaved()
    {
        var saved = await db.SavedMessages
            .Where(s => s.UserId == UserId)
            .OrderByDescending(s => s.SavedAt)
            .Select(s => new SavedMessageDto(
                s.Id,
                s.MessageId,
                s.Message.DeletedAt == null
                    ? (s.Message.Sender.Nickname ?? s.Message.Sender.DisplayName)
                    : "",
                s.Message.Type,
                s.Message.DeletedAt == null ? s.Message.Body : null,
                s.Message.DeletedAt == null ? s.Message.MediaUrl : null,
                s.Message.DeletedAt == null ? s.Message.DurationSeconds : null,
                s.Message.SentAt,
                s.SavedAt,
                s.Message.DeletedAt != null))
            .ToListAsync();

        if (saved.Any(s => s.MediaUrl != null))
        {
            try
            {
                var (key, keyExpiry) = await blob.GetReadDelegationKeyAsync();
                saved = saved.Select(s => s.MediaUrl != null
                    ? s with { MediaUrl = blob.GenerateFreshReadUrl(s.MediaUrl, key, keyExpiry) }
                    : s).ToList();
            }
            catch (Exception ex)
            {
                // Local dev fallback — serve plain URLs if delegation key unavailable
                logger.LogWarning(ex, "[GetSaved] could not get delegation key; serving plain URLs");
            }
        }

        return saved;
    }

    [HttpPost("{messageId}/save")]
    public async Task<IActionResult> SaveMessage(Guid messageId)
    {
        var message = await db.Messages.FindAsync(messageId);
        if (message is null) return NotFound();

        var isMember = await db.Memberships
            .AnyAsync(m => m.UserId == UserId && m.ClubId == message.ClubId);
        if (!isMember) return Forbid();

        var alreadySaved = await db.SavedMessages
            .AnyAsync(s => s.UserId == UserId && s.MessageId == messageId);
        if (alreadySaved) return Ok();

        db.SavedMessages.Add(new SavedMessage { UserId = UserId, MessageId = messageId });
        await db.SaveChangesAsync();
        return Ok();
    }

    [HttpDelete("{messageId}/save")]
    public async Task<IActionResult> UnsaveMessage(Guid messageId)
    {
        var saved = await db.SavedMessages
            .FirstOrDefaultAsync(s => s.UserId == UserId && s.MessageId == messageId);
        if (saved is null) return NoContent();

        db.SavedMessages.Remove(saved);
        await db.SaveChangesAsync();
        return NoContent();
    }

    [HttpPost("{messageId}/report")]
    public async Task<IActionResult> ReportMessage(Guid messageId)
    {
        var message = await db.Messages
            .Include(m => m.Sender)
            .FirstOrDefaultAsync(m => m.Id == messageId);
        if (message is null) return NotFound();

        var isMember = await db.Memberships
            .AnyAsync(m => m.UserId == UserId && m.ClubId == message.ClubId);
        if (!isMember) return Forbid();

        var alreadyReported = await db.Reports
            .AnyAsync(r => r.ReporterId == UserId && r.MessageId == messageId);
        if (!alreadyReported)
        {
            db.Reports.Add(new Report { ReporterId = UserId, MessageId = messageId });
            await db.SaveChangesAsync();
        }

        return Ok();
    }
}
