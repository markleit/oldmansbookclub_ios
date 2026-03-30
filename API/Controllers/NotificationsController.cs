using BookClubApi.Data;
using BookClubApi.Models;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

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
        var user = await db.Users.FindAsync(UserId);
        if (user is null) return NotFound();

        user.DeviceToken = request.DeviceToken;
        await db.SaveChangesAsync();
        return Ok();
    }
}
