using BookClubApi.Data;
using BookClubApi.Models;
using BookClubApi.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.RateLimiting;
using Microsoft.EntityFrameworkCore;

namespace BookClubApi.Controllers;

[Authorize]
[ApiController]
[Route("[controller]")]
[EnableRateLimiting("media")]
public class MediaController(BlobService blobService, AppDbContext db) : ControllerBase
{
    private Guid UserId => Guid.Parse(User.FindFirst("sub")!.Value);

    [HttpPost("upload-url")]
    public async Task<ActionResult<UploadUrlResponse>> GetUploadUrl([FromQuery] Guid clubId, [FromQuery] string? ext = null)
    {
        var isMember = await db.Memberships
            .AnyAsync(m => m.UserId == UserId && m.ClubId == clubId);
        if (!isMember) return Forbid();

        var (uploadUrl, mediaUrl) = await blobService.GenerateUploadUrlAsync(clubId, ext);
        return new UploadUrlResponse(uploadUrl, mediaUrl);
    }

    [HttpPost("avatar-upload-url")]
    public async Task<UploadUrlResponse> GetAvatarUploadUrl()
    {
        var (uploadUrl, avatarUrl) = await blobService.GenerateAvatarUploadUrlAsync(UserId);
        return new UploadUrlResponse(uploadUrl, avatarUrl);
    }
}
