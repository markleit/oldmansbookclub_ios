using BookClubApi.Data;
using BookClubApi.Models;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;

namespace BookClubApi.Controllers;

[Authorize]
[ApiController]
[Route("[controller]")]
public class EventsController(AppDbContext db) : ControllerBase
{
    private Guid UserId => Guid.Parse(User.FindFirst("sub")!.Value);

    // All upcoming events across the user's clubs
    [HttpGet]
    public async Task<IEnumerable<EventDto>> GetMyEvents()
    {
        var myClubIds = await db.Memberships
            .Where(m => m.UserId == UserId)
            .Select(m => m.ClubId)
            .ToListAsync();

        return await db.Events
            .Where(e => myClubIds.Contains(e.ClubId) && e.Date >= DateTime.UtcNow)
            .OrderBy(e => e.Date)
            .Select(e => new EventDto(e.Id, e.ClubId, e.Title, e.Date, e.Location))
            .ToListAsync();
    }

    // Events for a specific club
    [HttpGet("club/{clubId}")]
    public async Task<IEnumerable<EventDto>> GetClubEvents(Guid clubId)
    {
        var isMember = await db.Memberships
            .AnyAsync(m => m.UserId == UserId && m.ClubId == clubId);
        if (!isMember) return [];

        return await db.Events
            .Where(e => e.ClubId == clubId)
            .OrderBy(e => e.Date)
            .Select(e => new EventDto(e.Id, e.ClubId, e.Title, e.Date, e.Location))
            .ToListAsync();
    }

    [HttpPost("club/{clubId}")]
    public async Task<ActionResult<EventDto>> CreateEvent(Guid clubId, [FromBody] CreateEventRequest request)
    {
        var isMember = await db.Memberships
            .AnyAsync(m => m.UserId == UserId && m.ClubId == clubId);
        if (!isMember) return Forbid();

        var ev = new Event
        {
            ClubId = clubId,
            Title = request.Title,
            Date = request.Date,
            Location = request.Location
        };

        db.Events.Add(ev);
        await db.SaveChangesAsync();

        return CreatedAtAction(nameof(GetClubEvents), new { clubId },
            new EventDto(ev.Id, ev.ClubId, ev.Title, ev.Date, ev.Location));
    }
}
