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
    [HttpPost("seed-join-request")]
    public async Task<IActionResult> SeedJoinRequest([FromBody] string displayName)
    {
        if (!HttpContext.RequestServices.GetRequiredService<IWebHostEnvironment>().IsDevelopment())
            return NotFound();

        var subject = "dev_" + displayName.ToLowerInvariant();
        var user = await db.Users.FirstOrDefaultAsync(u => u.AppleSubject == subject);
        if (user is null)
        {
            user = new User { AppleSubject = subject, DisplayName = displayName, IsApproved = false };
            db.Users.Add(user);
            await db.SaveChangesAsync();
        }

        var club = await db.Clubs.FirstOrDefaultAsync();
        if (club is null) return NotFound("No clubs exist.");

        var existing = await db.JoinRequests
            .FirstOrDefaultAsync(jr => jr.UserId == user.Id && jr.ClubId == club.Id);
        if (existing is not null)
        {
            existing.Status = JoinRequestStatus.Pending;
            await db.SaveChangesAsync();
            return Ok(new { userId = user.Id, clubId = club.Id, status = "reset to pending" });
        }

        db.JoinRequests.Add(new JoinRequest { UserId = user.Id, ClubId = club.Id });
        await db.SaveChangesAsync();
        return Ok(new { userId = user.Id, clubId = club.Id, status = "created" });
    }

    [HttpPost("seed-messages")]
    public async Task<IActionResult> SeedMessages([FromBody] SeedMessagesRequest req)
    {
        var seedKey = config["Seeding:Key"];
        var headerKey = Request.Headers["X-Seed-Key"].FirstOrDefault();
        var hasValidKey = seedKey is not null && headerKey == seedKey;
        if (!hasValidKey && !await IsAdminAsync()) return Forbid();

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
                    msg.Body, msg.MediaUrl, msg.DurationSeconds, msg.SentAt,
                    IsDeleted: false, IsForwarded: false);
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

        // Delete reports and saved messages that reference this user's messages
        var messageIds = await db.Messages
            .Where(m => m.SenderId == id)
            .Select(m => m.Id)
            .ToListAsync();
        if (messageIds.Count > 0)
        {
            await db.Reports.Where(r => messageIds.Contains(r.MessageId)).ExecuteDeleteAsync();
            await db.SavedMessages.Where(s => messageIds.Contains(s.MessageId)).ExecuteDeleteAsync();
        }

        await db.Reports.Where(r => r.ReporterId == id).ExecuteDeleteAsync();
        await db.SavedMessages.Where(s => s.UserId == id).ExecuteDeleteAsync();
        await db.Messages.Where(m => m.SenderId == id).ExecuteDeleteAsync();
        await db.JoinRequests.Where(jr => jr.UserId == id).ExecuteDeleteAsync();
        await db.BlockedUsers.Where(b => b.BlockerId == id || b.BlockedId == id).ExecuteDeleteAsync();
        db.Memberships.RemoveRange(user.Memberships);
        db.Users.Remove(user);
        await db.SaveChangesAsync();
        return NoContent();
    }

    [HttpPost("clubs/{clubId}/members/{userId}/set-club-admin")]
    public async Task<IActionResult> SetClubAdmin(Guid clubId, Guid userId, [FromBody] SetClubAdminRequest req)
    {
        if (!await IsAdminAsync()) return Forbid();
        var membership = await db.Memberships.FirstOrDefaultAsync(m => m.UserId == userId && m.ClubId == clubId);
        if (membership is null) return NotFound();
        membership.IsClubAdmin = req.IsClubAdmin;
        await db.SaveChangesAsync();
        return NoContent();
    }

    [HttpDelete("clubs/{clubId}/members/{userId}")]
    public async Task<IActionResult> RemoveMember(Guid clubId, Guid userId)
    {
        var callerId = CallerId();
        if (callerId == Guid.Empty) return Unauthorized();
        if (!await CanManageClub(callerId, clubId)) return Forbid();
        if (callerId == userId) return BadRequest("Cannot remove yourself from a club.");
        var membership = await db.Memberships.FirstOrDefaultAsync(m => m.UserId == userId && m.ClubId == clubId);
        if (membership is null) return NoContent();
        db.Memberships.Remove(membership);
        await db.SaveChangesAsync();
        return NoContent();
    }

    [HttpDelete("clubs/{id}")]
    public async Task<IActionResult> DeleteClub(Guid id)
    {
        if (!await IsAdminAsync()) return Forbid();
        var club = await db.Clubs
            .Include(c => c.Memberships)
            .FirstOrDefaultAsync(c => c.Id == id);
        if (club is null) return NotFound();
        db.Memberships.RemoveRange(club.Memberships);
        db.Clubs.Remove(club);
        await db.SaveChangesAsync();
        return NoContent();
    }

    [HttpGet("reports")]
    public async Task<ActionResult<List<ReportDto>>> GetReports()
    {
        if (!await IsAdminAsync()) return Forbid();
        var reports = await db.Reports
            .Include(r => r.Reporter)
            .Include(r => r.Message).ThenInclude(m => m.Sender)
            .OrderByDescending(r => r.CreatedAt)
            .Select(r => new ReportDto(
                r.Id,
                r.MessageId,
                r.Reporter.Nickname ?? r.Reporter.DisplayName,
                r.Message.Sender.Nickname ?? r.Message.Sender.DisplayName,
                r.Message.Type,
                r.Message.Body,
                r.Message.SentAt,
                r.CreatedAt))
            .ToListAsync();
        return Ok(reports);
    }

    [HttpDelete("reports/{id}")]
    public async Task<IActionResult> DismissReport(Guid id)
    {
        if (!await IsAdminAsync()) return Forbid();
        var report = await db.Reports.FindAsync(id);
        if (report is null) return NoContent();
        db.Reports.Remove(report);
        await db.SaveChangesAsync();
        return NoContent();
    }

    [HttpDelete("messages/{id}")]
    public async Task<IActionResult> DeleteMessage(Guid id)
    {
        if (!await IsAdminAsync()) return Forbid();
        await db.Reports.Where(r => r.MessageId == id).ExecuteDeleteAsync();
        await db.SavedMessages.Where(s => s.MessageId == id).ExecuteDeleteAsync();
        await db.Messages.Where(m => m.Id == id).ExecuteDeleteAsync();
        return NoContent();
    }

    [HttpGet("join-requests")]
    public async Task<ActionResult<List<JoinRequestDto>>> GetJoinRequests()
    {
        var userId = CallerId();
        if (userId == Guid.Empty) return Unauthorized();
        var isGlobalAdmin = await IsAdminAsync();
        List<Guid> scopedClubIds;
        if (isGlobalAdmin)
        {
            scopedClubIds = await db.Clubs.Select(c => c.Id).ToListAsync();
        }
        else
        {
            scopedClubIds = await db.Memberships
                .Where(m => m.UserId == userId && m.IsClubAdmin)
                .Select(m => m.ClubId)
                .ToListAsync();
            if (scopedClubIds.Count == 0) return Forbid();
        }
        var requests = await db.JoinRequests
            .Include(jr => jr.User)
            .Include(jr => jr.Club)
            .Where(jr => scopedClubIds.Contains(jr.ClubId) && jr.Status == JoinRequestStatus.Pending)
            .OrderBy(jr => jr.CreatedAt)
            .Select(jr => new JoinRequestDto(jr.Id, jr.UserId, jr.User.DisplayName, jr.User.Email, jr.ClubId, jr.Club.Name, jr.CreatedAt))
            .ToListAsync();
        return Ok(requests);
    }

    [HttpPost("join-requests/{id}/approve")]
    public async Task<IActionResult> ApproveJoinRequest(Guid id)
    {
        var userId = CallerId();
        if (userId == Guid.Empty) return Unauthorized();
        var jr = await db.JoinRequests
            .Include(j => j.User)
            .Include(j => j.Club)
            .FirstOrDefaultAsync(j => j.Id == id);
        if (jr is null) return NotFound();
        if (!await CanManageClub(userId, jr.ClubId)) return Forbid();
        jr.Status = JoinRequestStatus.Approved;
        jr.User.IsApproved = true;
        var alreadyMember = await db.Memberships.AnyAsync(m => m.UserId == jr.UserId && m.ClubId == jr.ClubId);
        if (!alreadyMember)
            db.Memberships.Add(new Membership { UserId = jr.UserId, ClubId = jr.ClubId });
        await db.SaveChangesAsync();

        if (jr.User.DeviceToken is not null)
            _ = notifications.SendJoinResponseNotificationAsync(jr.User.DeviceToken, jr.Club.Name, approved: true);

        return Ok();
    }

    [HttpPost("join-requests/{id}/decline")]
    public async Task<IActionResult> DeclineJoinRequest(Guid id)
    {
        var userId = CallerId();
        if (userId == Guid.Empty) return Unauthorized();
        var jr = await db.JoinRequests
            .Include(j => j.User)
            .Include(j => j.Club)
            .FirstOrDefaultAsync(j => j.Id == id);
        if (jr is null) return NotFound();
        if (!await CanManageClub(userId, jr.ClubId)) return Forbid();
        jr.Status = JoinRequestStatus.Declined;
        await db.SaveChangesAsync();

        if (jr.User.DeviceToken is not null)
            _ = notifications.SendJoinResponseNotificationAsync(jr.User.DeviceToken, jr.Club.Name, approved: false);

        return Ok();
    }

    private Guid CallerId()
    {
        var sub = User.FindFirst("sub")?.Value;
        return Guid.TryParse(sub, out var id) ? id : Guid.Empty;
    }

    private async Task<bool> CanManageClub(Guid userId, Guid clubId)
    {
        if (await IsAdminAsync()) return true;
        return await db.Memberships.AnyAsync(m => m.UserId == userId && m.ClubId == clubId && m.IsClubAdmin);
    }

    private async Task<bool> IsAdminAsync()
    {
        var sub = User.FindFirst("sub")?.Value;
        if (sub is null || !Guid.TryParse(sub, out var userId)) return false;
        return await db.Users.Where(u => u.Id == userId).Select(u => u.IsAdmin).FirstOrDefaultAsync();
    }
}
