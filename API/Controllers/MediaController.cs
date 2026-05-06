using BookClubApi.Models;
using BookClubApi.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace BookClubApi.Controllers;

[Authorize]
[ApiController]
[Route("[controller]")]
public class MediaController(BlobService blobService) : ControllerBase
{
    [HttpPost("upload-url")]
    public async Task<UploadUrlResponse> GetUploadUrl([FromQuery] Guid clubId)
    {
        var (uploadUrl, mediaUrl) = await blobService.GenerateUploadUrlAsync(clubId);
        return new UploadUrlResponse(uploadUrl, mediaUrl);
    }

    [HttpPost("avatar-upload-url")]
    public async Task<UploadUrlResponse> GetAvatarUploadUrl()
    {
        var userId = Guid.Parse(User.FindFirst("sub")?.Value
            ?? throw new UnauthorizedAccessException());
        var (uploadUrl, avatarUrl) = await blobService.GenerateAvatarUploadUrlAsync(userId);
        return new UploadUrlResponse(uploadUrl, avatarUrl);
    }
}
