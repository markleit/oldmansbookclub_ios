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
public class MediaController(BlobService blobService, AppDbContext db, MessageSendService messageSend) : ControllerBase
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

    // #204 design v2 — upload slots fetched in advance (MessageSendService.IssueVideoSlotsAsync).
    // Accepts the send token, whose sign-in the slots then belong to.
    [HttpPost("video-slots")]
    [AcceptsSendToken]
    public async Task<ActionResult<VideoSlotsResponse>> GetVideoSlots([FromQuery] Guid clubId, [FromQuery] int count = 3)
    {
        try
        {
            var sender = await messageSend.LoadSenderContextAsync(UserId);
            Guid? session = Guid.TryParse(User.FindFirst(SendToken.SessionClaim)?.Value, out var sid) ? sid : null;
            return new VideoSlotsResponse(await messageSend.IssueVideoSlotsAsync(UserId, sender, clubId, count, session));
        }
        catch (MessageSendException ex)
        {
            return BadRequest(new { error = ex.Message });
        }
    }

    [HttpPost("avatar-upload-url")]
    public async Task<UploadUrlResponse> GetAvatarUploadUrl()
    {
        var (uploadUrl, avatarUrl) = await blobService.GenerateAvatarUploadUrlAsync(UserId);
        return new UploadUrlResponse(uploadUrl, avatarUrl);
    }
}
