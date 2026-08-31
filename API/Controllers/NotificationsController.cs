using BookClubApi.Data;
using BookClubApi.Models;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;

namespace BookClubApi.Controllers;

[Authorize]
[ApiController]
[Route("[controller]")]
public class NotificationsController(AppDbContext db) : ControllerBase
{
    private Guid UserId => Guid.Parse(User.FindFirst("sub")!.Value);

    [HttpPost("register")]
    public async Task<IActionResult> RegisterDevice([FromBody] RegisterDeviceRequest request)
    {
        var userExists = await db.Users.AnyAsync(u => u.Id == UserId);
        if (!userExists) return NotFound();

        // #25 — a physical device's token is globally unique, so this is a claim, not a plain
        // insert: dev-login/demo/test sessions on the same device previously smeared one token
        // across multiple User rows because the old model let every account hold its own copy.
        var existing = await db.UserDevices.FirstOrDefaultAsync(d => d.DeviceToken == request.DeviceToken);
        if (existing is not null)
        {
            existing.UserId = UserId;
            existing.LastSeenAt = DateTime.UtcNow;
        }
        else
        {
            db.UserDevices.Add(new UserDevice { UserId = UserId, DeviceToken = request.DeviceToken });
        }

        await db.SaveChangesAsync();
        return Ok();
    }
}
