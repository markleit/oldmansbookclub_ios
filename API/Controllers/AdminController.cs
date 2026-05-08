using BookClubApi.Data;
using BookClubApi.Models;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;

namespace BookClubApi.Controllers;

[Authorize]
[ApiController]
[Route("[controller]")]
public class AdminController(AppDbContext db) : ControllerBase
{
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

    private async Task<bool> IsAdminAsync()
    {
        var sub = User.FindFirst("sub")?.Value;
        if (sub is null || !Guid.TryParse(sub, out var userId)) return false;
        return await db.Users.Where(u => u.Id == userId).Select(u => u.IsAdmin).FirstOrDefaultAsync();
    }
}
