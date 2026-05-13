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
public class UsersController(AppDbContext db, BlobService blob) : ControllerBase
{
    [HttpGet]
    public async Task<ActionResult<List<UserDto>>> GetMembers()
    {
        var users = await db.Users
            .Where(u => u.IsApproved)
            .OrderBy(u => u.DisplayName)
            .ToListAsync();
        var dtos = await Task.WhenAll(users.Select(ToDto));
        return Ok(dtos);
    }

    [HttpGet("me")]
    public async Task<ActionResult<UserDto>> GetMe()
    {
        var userId = GetUserId();
        var user = await db.Users.FindAsync(userId);
        if (user is null) return NotFound();
        return await ToDto(user);
    }

    [HttpPatch("me")]
    public async Task<ActionResult<UserDto>> UpdateMe([FromBody] UpdateProfileRequest req)
    {
        var userId = GetUserId();
        var user = await db.Users.FindAsync(userId);
        if (user is null) return NotFound();

        if (!string.IsNullOrWhiteSpace(req.DisplayName)) user.DisplayName = req.DisplayName.Trim();
        if (req.Nickname is not null) user.Nickname = req.Nickname.Trim().Length > 0 ? req.Nickname.Trim() : null;
        if (req.AvatarUrl is not null)
        {
            if (!IsOwnBlobUrl(req.AvatarUrl)) return BadRequest("Invalid avatar URL.");
            user.AvatarUrl = req.AvatarUrl;
        }

        await db.SaveChangesAsync();
        return await ToDto(user);
    }

    [HttpGet("blocked")]
    public async Task<ActionResult<List<Guid>>> GetBlocked()
    {
        var userId = GetUserId();
        var ids = await db.BlockedUsers
            .Where(b => b.BlockerId == userId)
            .Select(b => b.BlockedId)
            .ToListAsync();
        return Ok(ids);
    }

    [HttpPost("{userId}/block")]
    public async Task<IActionResult> BlockUser(Guid userId)
    {
        var blockerId = GetUserId();
        if (blockerId == userId) return BadRequest("Cannot block yourself.");

        var blocked = await db.Users.FindAsync(userId);
        if (blocked is null) return NotFound();

        var alreadyBlocked = await db.BlockedUsers
            .AnyAsync(b => b.BlockerId == blockerId && b.BlockedId == userId);
        if (!alreadyBlocked)
        {
            db.BlockedUsers.Add(new BlockedUser { BlockerId = blockerId, BlockedId = userId });
            await db.SaveChangesAsync();
        }

        return Ok();
    }

    [HttpDelete("{userId}/block")]
    public async Task<IActionResult> UnblockUser(Guid userId)
    {
        var blockerId = GetUserId();
        var record = await db.BlockedUsers
            .FirstOrDefaultAsync(b => b.BlockerId == blockerId && b.BlockedId == userId);
        if (record is null) return NoContent();

        db.BlockedUsers.Remove(record);
        await db.SaveChangesAsync();
        return NoContent();
    }

    private Guid GetUserId() =>
        Guid.Parse(User.FindFirst("sub")?.Value
            ?? throw new UnauthorizedAccessException());

    private static bool IsOwnBlobUrl(string url) =>
        Uri.TryCreate(url, UriKind.Absolute, out var uri) &&
        uri.Scheme == "https" &&
        uri.Host.EndsWith(".blob.core.windows.net");

    private async Task<UserDto> ToDto(User u)
    {
        var avatarUrl = u.AvatarUrl is not null
            ? await blob.GenerateAvatarReadUrlAsync(u.Id)
            : null;
        return new UserDto(u.Id, u.DisplayName, u.Nickname, avatarUrl, u.IsAdmin);
    }
}
