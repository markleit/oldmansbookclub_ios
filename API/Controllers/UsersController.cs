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
    public async Task<ActionResult<List<UserDto>>> GetMembers([FromQuery] Guid? clubId = null)
    {
        var userId = GetUserId();
        var myClubIds = await db.Memberships
            .Where(m => m.UserId == userId)
            .Select(m => m.ClubId)
            .ToListAsync();

        if (clubId.HasValue && !myClubIds.Contains(clubId.Value))
            return Forbid();

        var targetClubIds = clubId.HasValue ? [clubId.Value] : myClubIds;
        var users = await db.Users
            .Where(u => u.IsApproved && db.Memberships.Any(m => m.UserId == u.Id && targetClubIds.Contains(m.ClubId)))
            .OrderBy(u => u.DisplayName)
            .ToListAsync();
        var dtos = await BuildDtos(users);
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
            // Bake a cache-bust version into the stored URL as a fragment. Avatar
            // blobs reuse a fixed path per user; without this hint, downstream
            // consumers (sender avatars in messages, etc.) would key the iOS image
            // cache by path alone and serve the old bytes after a replacement.
            var now = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
            user.AvatarUrl = $"{req.AvatarUrl}#v={now}";
            user.AvatarUpdatedAt = DateTime.UtcNow;
        }
        if (req.Preferences?.TapToTalk.HasValue == true)
            user.Preferences.TapToTalk = req.Preferences.TapToTalk.Value;

        await db.SaveChangesAsync();
        return await ToDto(user);
    }

    [HttpGet("blocked")]
    public async Task<ActionResult<List<UserDto>>> GetBlocked()
    {
        var userId = GetUserId();
        var blocked = await db.BlockedUsers
            .Where(b => b.BlockerId == userId)
            .Include(b => b.Blocked)
            .Select(b => b.Blocked)
            .ToListAsync();
        var dtos = await BuildDtos(blocked);
        return Ok(dtos);
    }

    [HttpGet("blocked-ids")]
    public async Task<ActionResult<List<Guid>>> GetBlockedIds()
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

    private const string AllowedBlobHost = "oldmansbookclubstore.blob.core.windows.net";

    private static bool IsOwnBlobUrl(string url) =>
        Uri.TryCreate(url, UriKind.Absolute, out var uri) &&
        uri.Scheme == "https" &&
        uri.Host == AllowedBlobHost;

    private async Task<UserDto[]> BuildDtos(IList<User> users)
    {
        var userIds = users.Select(u => u.Id).ToList();
        var clubAdminIds = await db.Memberships
            .Where(m => userIds.Contains(m.UserId) && m.IsClubAdmin)
            .Select(m => m.UserId)
            .ToHashSetAsync();
        var dtos = new UserDto[users.Count];
        for (var i = 0; i < users.Count; i++)
            dtos[i] = await ToDto(users[i], clubAdminIds.Contains(users[i].Id));
        return dtos;
    }

    private async Task<UserDto> ToDto(User u) =>
        await ToDto(u, await db.Memberships.AnyAsync(m => m.UserId == u.Id && m.IsClubAdmin));

    private async Task<UserDto> ToDto(User u, bool isClubAdmin)
    {
        var avatarUrl = u.AvatarUrl is not null
            ? await blob.GenerateAvatarReadUrlAsync(u.Id, u.AvatarUpdatedAt)
            : null;
        return new UserDto(u.Id, u.DisplayName, u.Nickname, avatarUrl, u.IsAdmin, isClubAdmin, new UserPreferencesDto(u.Preferences.TapToTalk));
    }
}
