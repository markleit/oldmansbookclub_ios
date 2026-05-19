using System.IdentityModel.Tokens.Jwt;
using System.Security.Claims;
using System.Text;
using BookClubApi.Data;
using BookClubApi.Models;
using BookClubApi.Services;
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
    BlobService blob) : ControllerBase
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

        var isMember = await db.Memberships.AnyAsync(m => m.UserId == user.Id);
        if (!isMember)
        {
            var club = await db.Clubs.FirstOrDefaultAsync();
            if (club is not null)
            {
                db.Memberships.Add(new Membership { UserId = user.Id, ClubId = club.Id });
                await db.SaveChangesAsync();
            }
        }

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

        var membership = await db.Memberships.FirstOrDefaultAsync(m => m.UserId == user.Id);
        if (membership is null)
        {
            var club = await db.Clubs.FirstOrDefaultAsync();
            if (club is null)
            {
                club = new Club { Id = Guid.NewGuid(), Name = "Old Man's Book Club" };
                db.Clubs.Add(club);
            }
            db.Memberships.Add(new Membership { UserId = user.Id, ClubId = club.Id, IsClubAdmin = true });
            await db.SaveChangesAsync();
        }
        else if (!membership.IsClubAdmin)
        {
            membership.IsClubAdmin = true;
            await db.SaveChangesAsync();
        }

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

        var isMember = await db.Memberships.AnyAsync(m => m.UserId == user.Id);
        if (!isMember)
        {
            var existingRequest = await db.JoinRequests
                .Include(jr => jr.Club)
                .FirstOrDefaultAsync(jr => jr.UserId == user.Id &&
                    (jr.Status == JoinRequestStatus.Pending || jr.Status == JoinRequestStatus.Declined));
            if (existingRequest != null)
            {
                var status = existingRequest.Status == JoinRequestStatus.Declined
                    ? "request_declined"
                    : "pending_approval";
                return StatusCode(202, new { status, club_name = existingRequest.Club.Name });
            }

            if (!string.IsNullOrWhiteSpace(request.ClubName))
            {
                var club = new Club { Id = Guid.NewGuid(), Name = request.ClubName.Trim() };
                db.Clubs.Add(club);
                db.Memberships.Add(new Membership { UserId = user.Id, ClubId = club.Id, IsClubAdmin = true });
                user.IsApproved = true;
                await db.SaveChangesAsync();
            }
            else if (request.JoinClubId.HasValue)
            {
                var club = await db.Clubs.FindAsync(request.JoinClubId.Value);
                if (club is null) return NotFound("Club not found.");

                var alreadyRequested = await db.JoinRequests
                    .AnyAsync(jr => jr.UserId == user.Id && jr.ClubId == request.JoinClubId.Value);
                if (!alreadyRequested)
                {
                    db.JoinRequests.Add(new JoinRequest { UserId = user.Id, ClubId = request.JoinClubId.Value });
                    await db.SaveChangesAsync();
                }
                return StatusCode(202, new { status = "pending_approval", club_name = club.Name });
            }
            else
            {
                return StatusCode(202, new { status = "needs_club_setup" });
            }
        }

        var token = GenerateJwt(user);
        return Ok(new AuthResponse(token, await BuildUserDto(user)));
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
