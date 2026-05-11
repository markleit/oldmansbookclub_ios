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
public class AdminController(AppDbContext db, IConfiguration config, NotificationService notifications) : ControllerBase
{
    private static readonly string[] SampleTexts =
    [
        "I wasn't expecting that twist at all. Anyone else see it coming?",
        "The pacing in this section feels a bit slow but I trust where it's going.",
        "That dialogue between the two main characters was genuinely moving.",
        "I had to reread that chapter twice. Dense but worth it.",
        "The world-building here is exceptional. So much depth.",
        "Not sure I buy the main character's motivation in this part.",
        "This is exactly why I recommended this book. Incredible writing.",
        "Anyone else reading this on the commute? Hard to put down.",
        "The author's use of perspective shifts is doing a lot of heavy lifting.",
        "I've read this author before but this one hits differently.",
        "That ending to the chapter left me wanting more immediately.",
        "Remind me — what did we decide about the meeting time next week?",
        "Strong contender for book of the year for me.",
        "The symbolism is a bit on the nose but I'm still enjoying it.",
        "Can't believe we almost didn't pick this one."
    ];

    private const string TestAudioUrl =
        "https://upload.wikimedia.org/wikipedia/commons/transcoded/c/c8/Example.ogg/Example.ogg.mp3";

    [AllowAnonymous]
    [HttpPost("seed-messages")]
    public async Task<IActionResult> SeedMessages([FromBody] SeedMessagesRequest req)
    {
        var seedKey = config["Seeding:Key"];
        var headerKey = Request.Headers["X-Seed-Key"].FirstOrDefault();
        if (headerKey != seedKey && !await IsAdminAsync()) return Forbid();

        var book = await db.Books.FirstOrDefaultAsync(b =>
            EF.Functions.Like(b.Title, $"%{req.BookTitle}%"));
        if (book is null) return NotFound(new { error = $"No book matching '{req.BookTitle}' found." });

        User? sender = req.SenderName is not null
            ? await db.Users.FirstOrDefaultAsync(u => u.DisplayName == req.SenderName)
            : await db.Users.FirstOrDefaultAsync(u => u.DisplayName == "TestUser");

        if (sender is null)
        {
            var sub = User.FindFirst("sub")?.Value;
            if (Guid.TryParse(sub, out var adminId))
                sender = await db.Users.FindAsync(adminId);
        }
        if (sender is null) return NotFound(new { error = "No sender found." });

        var type = req.Type.ToLowerInvariant() switch
        {
            "voice" or "audio" => MessageType.Voice,
            "photo" or "image" => MessageType.Photo,
            _ => MessageType.Text
        };

        var count = Math.Clamp(req.Count, 1, 20);
        var messages = new List<Message>();

        for (var i = 0; i < count; i++)
        {
            var msg = new Message
            {
                ClubId = book.ClubId,
                BookId = book.Id,
                SenderId = sender.Id,
                Type = type,
                SentAt = DateTime.UtcNow.AddSeconds(-(count - i))
            };

            switch (type)
            {
                case MessageType.Text:
                    msg.Body = SampleTexts[Random.Shared.Next(SampleTexts.Length)];
                    break;
                case MessageType.Photo:
                    msg.MediaUrl = $"https://picsum.photos/seed/{Guid.NewGuid()}/600/400";
                    break;
                case MessageType.Voice:
                    msg.MediaUrl = TestAudioUrl;
                    msg.DurationSeconds = Random.Shared.Next(5, 45);
                    break;
            }

            messages.Add(msg);
        }

        db.Messages.AddRange(messages);
        await db.SaveChangesAsync();

        var deviceTokens = await db.Memberships
            .Where(m => m.ClubId == book.ClubId && m.UserId != sender.Id)
            .Select(m => m.User.DeviceToken)
            .Where(t => t != null)
            .Cast<string>()
            .ToListAsync();

        if (deviceTokens.Count > 0)
        {
            foreach (var msg in messages)
            {
                var dto = new MessageDto(msg.Id, msg.ClubId, msg.SenderId,
                    sender.EffectiveName, sender.AvatarUrl, msg.Type,
                    msg.Body, msg.MediaUrl, msg.DurationSeconds, msg.SentAt);
                await notifications.SendNewMessageAsync(deviceTokens, dto, book.Title);
            }
        }

        return Ok(new { created = messages.Count, book = book.Title, sender = sender.DisplayName });
    }

    [HttpGet("pending-users")]
    public async Task<ActionResult<List<PendingUserDto>>> GetPendingUsers()
    {
        if (!await IsAdminAsync()) return Forbid();
        var users = await db.Users
            .Where(u => !u.IsApproved)
            .OrderBy(u => u.CreatedAt)
            .Select(u => new PendingUserDto(u.Id, u.DisplayName, u.Email, u.CreatedAt))
            .ToListAsync();
        return Ok(users);
    }

    [HttpPost("users/{id}/approve")]
    public async Task<IActionResult> ApproveUser(Guid id)
    {
        if (!await IsAdminAsync()) return Forbid();
        var user = await db.Users.FindAsync(id);
        if (user is null) return NotFound();
        user.IsApproved = true;
        await db.SaveChangesAsync();
        return NoContent();
    }

    [HttpPost("users/{id}/set-role")]
    public async Task<IActionResult> SetRole(Guid id, [FromBody] SetRoleRequest req)
    {
        if (!await IsAdminAsync()) return Forbid();
        var sub = User.FindFirst("sub")?.Value;
        if (Guid.TryParse(sub, out var callerId) && callerId == id && !req.IsAdmin)
            return BadRequest("Cannot remove your own admin role.");
        var user = await db.Users.FindAsync(id);
        if (user is null) return NotFound();
        user.IsAdmin = req.IsAdmin;
        await db.SaveChangesAsync();
        return NoContent();
    }

    [HttpDelete("users/{id}")]
    public async Task<IActionResult> DeleteUser(Guid id)
    {
        if (!await IsAdminAsync()) return Forbid();
        var sub = User.FindFirst("sub")?.Value;
        if (Guid.TryParse(sub, out var callerId) && callerId == id)
            return BadRequest("Cannot delete your own account.");
        var user = await db.Users.Include(u => u.Memberships).FirstOrDefaultAsync(u => u.Id == id);
        if (user is null) return NotFound();
        db.Memberships.RemoveRange(user.Memberships);
        db.Users.Remove(user);
        await db.SaveChangesAsync();
        return NoContent();
    }

    private async Task<bool> IsAdminAsync()
    {
        var sub = User.FindFirst("sub")?.Value;
        if (sub is null || !Guid.TryParse(sub, out var userId)) return false;
        return await db.Users.Where(u => u.Id == userId).Select(u => u.IsAdmin).FirstOrDefaultAsync();
    }
}
