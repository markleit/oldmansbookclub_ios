using BookClubApi.Data;
using BookClubApi.Models;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;

namespace BookClubApi.Controllers;

[Authorize]
[ApiController]
[Route("[controller]")]
public class ClubsController(AppDbContext db) : ControllerBase
{
    private Guid UserId => Guid.Parse(User.FindFirst("sub")!.Value);

    [HttpGet]
    public async Task<IEnumerable<Club>> GetMyClubs() =>
        await db.Memberships
            .Where(m => m.UserId == UserId)
            .Select(m => m.Club)
            .ToListAsync();

    [HttpPost]
    public async Task<ActionResult<Club>> CreateClub([FromBody] CreateClubRequest request)
    {
        var club = new Club { Name = request.Name, Description = request.Description };
        db.Clubs.Add(club);
        db.Memberships.Add(new Membership { UserId = UserId, ClubId = club.Id });
        await db.SaveChangesAsync();
        return CreatedAtAction(nameof(GetMyClubs), club);
    }

    [HttpGet("{clubId}/messages")]
    public async Task<ActionResult<IEnumerable<MessageDto>>> GetMessages(
        Guid clubId, [FromQuery] DateTime? before, [FromQuery] int limit = 50)
    {
        var isMember = await db.Memberships
            .AnyAsync(m => m.UserId == UserId && m.ClubId == clubId);
        if (!isMember) return Forbid();

        var query = db.Messages
            .Where(m => m.ClubId == clubId && m.DeletedAt == null);

        if (before.HasValue)
            query = query.Where(m => m.SentAt < before.Value);

        return await query
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
    }

    [HttpPost("{clubId}/members")]
    public async Task<IActionResult> AddMember(Guid clubId, [FromBody] Guid userId)
    {
        var callerIsMember = await db.Memberships
            .AnyAsync(m => m.UserId == UserId && m.ClubId == clubId);
        if (!callerIsMember) return Forbid();

        var targetExists = await db.Users.AnyAsync(u => u.Id == userId);
        if (!targetExists) return NotFound("User not found.");

        var alreadyMember = await db.Memberships
            .AnyAsync(m => m.UserId == userId && m.ClubId == clubId);
        if (alreadyMember) return Conflict("User is already a member.");

        db.Memberships.Add(new Membership { UserId = userId, ClubId = clubId });
        await db.SaveChangesAsync();
        return Ok();
    }
}
