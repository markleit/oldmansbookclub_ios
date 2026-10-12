using System.IdentityModel.Tokens.Jwt;
using BookClubApi.Data;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.EntityFrameworkCore;

namespace BookClubApi.Services;

/// Marks an endpoint that accepts a send token (see <see cref="SendToken"/>). Everything else
/// refuses one.
[AttributeUsage(AttributeTargets.Method)]
public sealed class AcceptsSendTokenAttribute : Attribute;

/// #204 design v2 — a token that can only send messages, handed out with every access token and
/// valid for a week. The app attaches it to a message it hands to iOS's background transfer, which
/// may wait a long time for the network (a phone off over a weekend). With the one-hour access
/// token that message would arrive unauthorized and need the app awake to refresh and resend —
/// the one step a locked phone can't take.
///
/// Tied to the sign-in it came with (its refresh token's id), so signing out on that phone, or
/// deleting the account, ends it at once rather than a week later. Access tokens carry no scope
/// and are untouched by any of this, so older clients are unaffected.
public static class SendToken
{
    public const string ScopeClaim = "scope";
    public const string Scope = "send";

    /// The id of the RefreshToken row — the sign-in this token belongs to.
    public const string SessionClaim = "sid";

    public static readonly TimeSpan Lifetime = TimeSpan.FromDays(7);

    /// JwtBearerEvents.OnTokenValidated. An access token passes untouched; a send token passes
    /// only on an endpoint marked [AcceptsSendToken], and only while its sign-in is still live.
    /// Failing here makes the request unauthenticated, so [Authorize] answers 401.
    public static async Task ValidateAsync(TokenValidatedContext context)
    {
        var principal = context.Principal;
        if (principal?.FindFirst(ScopeClaim)?.Value != Scope) return;

        if (context.HttpContext.GetEndpoint()?.Metadata.GetMetadata<AcceptsSendTokenAttribute>() is null)
        {
            context.Fail("A send token only works for sending messages.");
            return;
        }
        if (!Guid.TryParse(principal.FindFirst(SessionClaim)?.Value, out var session) ||
            !Guid.TryParse(principal.FindFirst(JwtRegisteredClaimNames.Sub)?.Value, out var userId))
        {
            context.Fail("Malformed send token.");
            return;
        }
        var db = context.HttpContext.RequestServices.GetRequiredService<AppDbContext>();
        var now = DateTime.UtcNow;
        var signedIn = await db.RefreshTokens.AnyAsync(rt =>
            rt.Id == session && rt.UserId == userId && rt.RevokedAt == null && rt.ExpiresAt > now);
        if (!signedIn) context.Fail("Signed out.");
    }
}
