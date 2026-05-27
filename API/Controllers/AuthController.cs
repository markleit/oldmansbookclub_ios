using System.IdentityModel.Tokens.Jwt;
using System.Security.Claims;
using System.Text;
using BookClubApi.Data;
using BookClubApi.Models;
using BookClubApi.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.RateLimiting;
using Microsoft.EntityFrameworkCore;
using Microsoft.IdentityModel.Tokens;

namespace BookClubApi.Controllers;

[ApiController]
[Route("[controller]")]
[EnableRateLimiting("auth")]
public class AuthController(
    AppDbContext db,
    AppleTokenValidator appleValidator,
    IConfiguration config,
    BlobService blob,
    NotificationService notifications) : ControllerBase
{
    private async Task<UserDto> BuildUserDto(User u)
    {
        var avatarUrl = u.AvatarUrl is not null
            ? await blob.GenerateAvatarReadUrlAsync(u.Id)
            : null;
        var isClubAdmin = await db.Memberships.AnyAsync(m => m.UserId == u.Id && m.IsClubAdmin);
        return new UserDto(u.Id, u.DisplayName, u.Nickname, avatarUrl, u.IsAdmin, isClubAdmin);
    }

    private const string DemoPassphrase = "BookClub2026";

    [HttpPost("demo-login")]
    public async Task<ActionResult<AuthResponse>> DemoLogin([FromBody] DemoLoginRequest request)
    {
        if (request.Passphrase != DemoPassphrase)
            return Unauthorized();

        const string reviewerSubject = "apple_reviewer";
        var user = await db.Users.FirstOrDefaultAsync(u => u.AppleSubject == reviewerSubject);
        if (user is null)
        {
            user = new User { AppleSubject = reviewerSubject, DisplayName = "Reviewer", IsApproved = true, IsAdmin = true };
            db.Users.Add(user);
            await db.SaveChangesAsync();
        }
        else if (!user.IsApproved || !user.IsAdmin)
        {
            user.IsApproved = true;
            user.IsAdmin = true;
            await db.SaveChangesAsync();
        }

        var existingClubIds = await db.Memberships
            .Where(m => m.UserId == user.Id)
            .Select(m => m.ClubId)
            .ToHashSetAsync();
        var allClubIds = await db.Clubs.Select(c => c.Id).ToListAsync();
        var missing = allClubIds.Where(id => !existingClubIds.Contains(id)).ToList();
        foreach (var clubId in missing)
            db.Memberships.Add(new Membership { UserId = user.Id, ClubId = clubId, IsClubAdmin = true });
        if (missing.Count > 0)
            await db.SaveChangesAsync();

        var token = GenerateJwt(user);
        return Ok(new AuthResponse(token, await BuildUserDto(user)));
    }

    [HttpPost("dev-login")]
    public async Task<ActionResult<AuthResponse>> DevLogin([FromBody] DevLoginRequest request)
    {
        if (!HttpContext.RequestServices.GetRequiredService<IWebHostEnvironment>().IsDevelopment())
            return NotFound();

        var subject = "dev_" + request.DisplayName.ToLowerInvariant();
        var user = await db.Users.FirstOrDefaultAsync(u => u.AppleSubject == subject);
        if (user is null)
        {
            user = new User { AppleSubject = subject, DisplayName = request.DisplayName, IsApproved = true, IsAdmin = true };
            db.Users.Add(user);
            await db.SaveChangesAsync();
        }
        else if (!user.IsAdmin)
        {
            user.IsAdmin = true;
            user.IsApproved = true;
            await db.SaveChangesAsync();
        }

        var allClubIds = await db.Clubs.Select(c => c.Id).ToListAsync();
        if (allClubIds.Count == 0)
        {
            var club = new Club { Id = Guid.NewGuid(), Name = "Old Man's Book Club" };
            db.Clubs.Add(club);
            await db.SaveChangesAsync();
            allClubIds = [club.Id];
        }

        var existingClubIds = await db.Memberships
            .Where(m => m.UserId == user.Id)
            .Select(m => m.ClubId)
            .ToHashSetAsync();

        var missing = allClubIds.Where(id => !existingClubIds.Contains(id)).ToList();
        foreach (var clubId in missing)
            db.Memberships.Add(new Membership { UserId = user.Id, ClubId = clubId, IsClubAdmin = true });

        if (missing.Count > 0)
            await db.SaveChangesAsync();

        var token = GenerateJwt(user);
        return Ok(new AuthResponse(token, await BuildUserDto(user)));
    }

    [HttpPost("apple")]
    public async Task<ActionResult<AuthResponse>> SignInWithApple([FromBody] AppleAuthRequest request)
    {
        var bundleId = config["Apple:BundleId"]
            ?? throw new InvalidOperationException("Apple:BundleId not configured");

        var appleSubject = await appleValidator.ValidateAsync(request.IdentityToken, bundleId);
        if (appleSubject is null)
            return Unauthorized("Invalid Apple identity token");

        var user = await db.Users.FirstOrDefaultAsync(u => u.AppleSubject == appleSubject);
        if (user is null)
        {
            user = new User { AppleSubject = appleSubject, DisplayName = request.DisplayName, Email = request.Email };
            db.Users.Add(user);
            await db.SaveChangesAsync();
        }
        else if (user.Email is null && request.Email is not null)
        {
            user.Email = request.Email;
            await db.SaveChangesAsync();
        }

        // Exchange authorization code for refresh token (only provided on first sign-in)
        if (request.AuthorizationCode is not null && user.AppleRefreshToken is null)
        {
            var refreshToken = await appleValidator.ExchangeCodeForRefreshTokenAsync(request.AuthorizationCode, bundleId);
            if (refreshToken is not null)
            {
                user.AppleRefreshToken = refreshToken;
                await db.SaveChangesAsync();
            }
        }

        var isMember = await db.Memberships.AnyAsync(m => m.UserId == user.Id);
        if (!isMember)
        {
            // Create a new club — takes priority over any prior declined request
            if (!string.IsNullOrWhiteSpace(request.ClubName))
            {
                var club = new Club { Id = Guid.NewGuid(), Name = request.ClubName.Trim() };
                db.Clubs.Add(club);
                db.Memberships.Add(new Membership { UserId = user.Id, ClubId = club.Id, IsClubAdmin = true });
                user.IsApproved = true;
                await db.SaveChangesAsync();
            }
            // Request to join a specific club
            else if (request.JoinClubId.HasValue)
            {
                var club = await db.Clubs.FindAsync(request.JoinClubId.Value);
                if (club is null) return NotFound("Club not found.");

                var jr = await db.JoinRequests
                    .FirstOrDefaultAsync(j => j.UserId == user.Id && j.ClubId == request.JoinClubId.Value);
                if (jr is null)
                {
                    db.JoinRequests.Add(new JoinRequest { UserId = user.Id, ClubId = request.JoinClubId.Value });
                    await db.SaveChangesAsync();

                    var adminTokens = await db.Memberships
                        .Where(m => m.ClubId == club.Id && m.IsClubAdmin && m.User.DeviceToken != null)
                        .Select(m => m.User.DeviceToken!)
                        .Distinct()
                        .ToListAsync();
                    if (adminTokens.Count > 0)
                        _ = notifications.SendJoinRequestNotificationAsync(adminTokens, user.DisplayName, club.Name);

                    return StatusCode(202, new { status = "pending_approval", club_name = club.Name });
                }
                return jr.Status switch
                {
                    JoinRequestStatus.Declined => StatusCode(202, new { status = "request_declined", club_name = club.Name }),
                    JoinRequestStatus.Approved => Ok(new AuthResponse(GenerateJwt(user), await BuildUserDto(user))),
                    _ => StatusCode(202, new { status = "pending_approval", club_name = club.Name })
                };
            }
            // Re-check status (e.g. user re-signs in from PendingApprovalView)
            else
            {
                var existingRequest = await db.JoinRequests
                    .Include(jr => jr.Club)
                    .Where(jr => jr.UserId == user.Id)
                    .OrderByDescending(jr => jr.CreatedAt)
                    .FirstOrDefaultAsync();

                if (existingRequest is not null)
                {
                    return existingRequest.Status switch
                    {
                        JoinRequestStatus.Declined => StatusCode(202, new { status = "request_declined", club_name = existingRequest.Club.Name }),
                        JoinRequestStatus.Approved => Ok(new AuthResponse(GenerateJwt(user), await BuildUserDto(user))),
                        _ => StatusCode(202, new { status = "pending_approval", club_name = existingRequest.Club.Name })
                    };
                }

                return StatusCode(202, new { status = "needs_club_setup" });
            }
        }

        var token = GenerateJwt(user);
        return Ok(new AuthResponse(token, await BuildUserDto(user)));
    }

    [Authorize]
    [HttpDelete("me")]
    public async Task<IActionResult> DeleteMyAccount()
    {
        var sub = User.FindFirst("sub")?.Value;
        if (!Guid.TryParse(sub, out var userId)) return Unauthorized();

        var user = await db.Users.Include(u => u.Memberships).FirstOrDefaultAsync(u => u.Id == userId);
        if (user is null) return NotFound();

        if (user.AppleRefreshToken is not null)
        {
            var bundleId = config["Apple:BundleId"] ?? throw new InvalidOperationException("Apple:BundleId not configured");
            _ = appleValidator.RevokeRefreshTokenAsync(user.AppleRefreshToken, bundleId);
        }

        var messageIds = await db.Messages
            .Where(m => m.SenderId == userId)
            .Select(m => m.Id)
            .ToListAsync();
        if (messageIds.Count > 0)
        {
            await db.Reports.Where(r => messageIds.Contains(r.MessageId)).ExecuteDeleteAsync();
            await db.SavedMessages.Where(s => messageIds.Contains(s.MessageId)).ExecuteDeleteAsync();
        }

        await db.Reports.Where(r => r.ReporterId == userId).ExecuteDeleteAsync();
        await db.SavedMessages.Where(s => s.UserId == userId).ExecuteDeleteAsync();
        await db.Messages.Where(m => m.SenderId == userId).ExecuteDeleteAsync();
        await db.JoinRequests.Where(jr => jr.UserId == userId).ExecuteDeleteAsync();
        await db.BlockedUsers.Where(b => b.BlockerId == userId || b.BlockedId == userId).ExecuteDeleteAsync();
        db.Memberships.RemoveRange(user.Memberships);
        db.Users.Remove(user);
        await db.SaveChangesAsync();

        return NoContent();
    }

    private string GenerateJwt(User user)
    {
        var key = new SymmetricSecurityKey(
            Encoding.UTF8.GetBytes(config["Jwt:Secret"]
                ?? throw new InvalidOperationException("Jwt:Secret not configured")));

        var claims = new[]
        {
            new Claim(JwtRegisteredClaimNames.Sub, user.Id.ToString()),
            new Claim(JwtRegisteredClaimNames.Jti, Guid.NewGuid().ToString())
        };

        var token = new JwtSecurityToken(
            issuer: config["Jwt:Issuer"],
            audience: config["Jwt:Audience"],
            claims: claims,
            expires: DateTime.UtcNow.AddDays(365),
            signingCredentials: new SigningCredentials(key, SecurityAlgorithms.HmacSha256));

        return new JwtSecurityTokenHandler().WriteToken(token);
    }
}
