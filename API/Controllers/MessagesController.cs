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
public class MessagesController(AppDbContext db, BlobService blob, MessageSendService messageSend, ILogger<MessagesController> logger) : ControllerBase
{
    private Guid UserId => Guid.Parse(User.FindFirst("sub")!.Value);

    // Background-safe send path: the client posts here (over a background URLSession, so it
    // survives arbitrary time in the background, not just the ~30s a BackgroundTaskBox grants)
    // instead of invoking the SignalR hub, which needs a live WebSocket and so can't run once
    // the app is suspended. Shares MessageSendService with ChatHub — same validation, same
    // clientId dedup, same broadcast to the book group — so behavior is identical either way.
    // ClientId is required here (unlike the hub's optional overloads) since every client build
    // that can reach this endpoint already generates one for every send.
    [HttpPost("~/books/{bookId}/messages")]
    public async Task<ActionResult<MessageDto>> SendMessage(Guid bookId, [FromBody] SendMessageRequest request)
    {
        try
        {
            var sender = await messageSend.LoadSenderContextAsync(UserId);
            MessageDto dto = request.Type switch
            {
                MessageType.Text => await messageSend.SendTextAsync(
                    UserId, sender, bookId, request.Body ?? "", request.ClientId, request.ParentMessageId, request.DeviceId),
                MessageType.Voice => await messageSend.SendVoiceAsync(
                    UserId, sender, bookId, request.MediaUrl ?? "", request.DurationSeconds ?? 0, request.ClientId, request.ParentMessageId, request.DeviceId),
                MessageType.Photo => await messageSend.SendPhotoAsync(
                    UserId, sender, bookId, request.MediaUrl ?? "", request.ClientId, request.ParentMessageId, request.DeviceId),
                MessageType.Video => await messageSend.SendVideoAsync(
                    UserId, sender, bookId, request.MediaUrl ?? "", request.ClientId, request.ParentMessageId, request.DeviceId),
                _ => throw new MessageSendException("Unsupported message type.")
            };
            return Ok(dto);
        }
        catch (MessageSendException ex)
        {
            return BadRequest(new { error = ex.Message });
        }
    }

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

    // Store an on-device transcript for a voice message so replies quoting it can show
    // its first words to everyone. Set-once (first transcription wins) to avoid churn.
    [HttpPost("{messageId}/transcript")]
    public async Task<IActionResult> SetTranscript(Guid messageId, [FromBody] SetTranscriptRequest request)
    {
        var message = await db.Messages.FindAsync(messageId);
        if (message is null) return NotFound();
        if (!await db.Memberships.AnyAsync(m => m.UserId == UserId && m.ClubId == message.ClubId)) return Forbid();
        if (message.Type != MessageType.Voice) return BadRequest("Only voice messages have transcripts.");

        if (string.IsNullOrWhiteSpace(message.Transcript) && !string.IsNullOrWhiteSpace(request.Transcript))
        {
            message.Transcript = request.Transcript.Length > 4000 ? request.Transcript[..4000] : request.Transcript;
            await db.SaveChangesAsync();
        }
        return Ok();
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
