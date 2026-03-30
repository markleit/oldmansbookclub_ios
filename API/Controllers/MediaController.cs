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
}
