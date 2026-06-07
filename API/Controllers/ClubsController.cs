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

    [AllowAnonymous]
    [HttpGet("public")]
    public async Task<IEnumerable<PublicClubDto>> GetPublicClubs() =>
        await db.Clubs
            .OrderBy(c => c.Name)
            .Select(c => new PublicClubDto(c.Id, c.Name, c.Memberships.Count()))
            .ToListAsync();

    [HttpGet]
    public async Task<IEnumerable<ClubMembershipDto>> GetMyClubs() =>
        await db.Memberships
            .Where(m => m.UserId == UserId)
            .Select(m => new ClubMembershipDto(m.Club.Id, m.Club.Name, m.Club.Description, m.IsClubAdmin))
            .ToListAsync();

    [HttpPost]
    public async Task<ActionResult<ClubDto>> CreateClub([FromBody] CreateClubRequest request)
    {
        var club = new Club { Name = request.Name, Description = request.Description };
        db.Clubs.Add(club);
        db.Memberships.Add(new Membership { UserId = UserId, ClubId = club.Id, IsClubAdmin = true });
        await db.SaveChangesAsync();
        return CreatedAtAction(nameof(GetMyClubs), new ClubDto(club.Id, club.Name, club.Description));
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
                m.DeletedAt == null ? m.ClientId : null))
            .ToListAsync();
    }

    [HttpPost("{clubId}/join-request")]
    public async Task<IActionResult> RequestToJoin(Guid clubId)
    {
        var userId = UserId;
        var club = await db.Clubs.FindAsync(clubId);
        if (club is null) return NotFound();

        var alreadyMember = await db.Memberships.AnyAsync(m => m.UserId == userId && m.ClubId == clubId);
        if (alreadyMember) return Conflict("Already a member of this club.");

        var existing = await db.JoinRequests
            .FirstOrDefaultAsync(jr => jr.UserId == userId && jr.ClubId == clubId);
        if (existing is not null)
        {
            if (existing.Status == JoinRequestStatus.Pending)
                return Conflict("A request is already pending.");
            existing.Status = JoinRequestStatus.Pending;
            existing.CreatedAt = DateTime.UtcNow;
            await db.SaveChangesAsync();
            return Ok();
        }

        db.JoinRequests.Add(new JoinRequest { UserId = userId, ClubId = clubId });
        await db.SaveChangesAsync();
        return Ok();
    }

    [HttpDelete("{clubId}/members/me")]
    public async Task<IActionResult> LeaveClub(Guid clubId)
    {
        var membership = await db.Memberships
            .FirstOrDefaultAsync(m => m.UserId == UserId && m.ClubId == clubId);
        if (membership is null) return NotFound();

        db.Memberships.Remove(membership);
        await db.SaveChangesAsync();
        return Ok();
    }

    [HttpPost("{clubId}/members")]
    public async Task<IActionResult> AddMember(Guid clubId, [FromBody] Guid userId)
    {
        var callerIsClubAdmin = await db.Memberships
            .AnyAsync(m => m.UserId == UserId && m.ClubId == clubId && m.IsClubAdmin);
        if (!callerIsClubAdmin) return Forbid();

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
