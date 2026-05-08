using BookClubApi.Data;
using BookClubApi.Models;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace BookClubApi.Controllers;

[Authorize]
[ApiController]
[Route("[controller]")]
public class UsersController(AppDbContext db) : ControllerBase
{
    [HttpGet("me")]
    public async Task<ActionResult<UserDto>> GetMe()
    {
        var userId = GetUserId();
        var user = await db.Users.FindAsync(userId);
        if (user is null) return NotFound();
        return ToDto(user);
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
        return ToDto(user);
    }

    private Guid GetUserId() =>
        Guid.Parse(User.FindFirst("sub")?.Value
            ?? throw new UnauthorizedAccessException());

    private static bool IsOwnBlobUrl(string url) =>
        Uri.TryCreate(url, UriKind.Absolute, out var uri) &&
        uri.Scheme == "https" &&
        uri.Host.EndsWith(".blob.core.windows.net");

    private static UserDto ToDto(User u) => new(u.Id, u.DisplayName, u.Nickname, u.AvatarUrl, u.IsAdmin);
}
