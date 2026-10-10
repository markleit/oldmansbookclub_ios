using System.Threading.RateLimiting;

namespace BookClubApi.Services;

/// The HTTP rate-limit partitions, shared by Program.cs and the integration test host so the
/// tests exercise the real partitioning with only the permit counts relaxed.
///
/// Both are partitioned — a limiter with no partition key is ONE bucket for the whole process,
/// so "N per minute" silently means N per minute for everybody combined (#154 for auth; the
/// upload-link limiter had the same bug until #204).
public static class RateLimitPolicies
{
    public const int AuthPerMinute = 10;
    public const int MediaPerMinute = 30;

    /// Auth endpoints, per caller IP — nobody is signed in yet. Needs UseForwardedHeaders first,
    /// or behind App Service's front end every caller has the proxy's address.
    public static RateLimitPartition<string> Auth(HttpContext httpContext, int permitLimit = AuthPerMinute) =>
        RateLimitPartition.GetFixedWindowLimiter(
            httpContext.Connection.RemoteIpAddress?.ToString() ?? "unknown",
            _ => Window(permitLimit));

    /// Upload links, per signed-in user (#204 — was one shared bucket, so a few members sending
    /// photo batches in the same minute could refuse everyone's upload links). Needs
    /// UseAuthentication BEFORE UseRateLimiter, or no user is known yet and every caller falls
    /// back to the IP partition.
    public static RateLimitPartition<string> Media(HttpContext httpContext, int permitLimit = MediaPerMinute) =>
        RateLimitPartition.GetFixedWindowLimiter(
            httpContext.User.FindFirst("sub")?.Value is { } sub
                ? "user:" + sub
                : "ip:" + (httpContext.Connection.RemoteIpAddress?.ToString() ?? "unknown"),
            _ => Window(permitLimit));

    private static FixedWindowRateLimiterOptions Window(int permitLimit) => new()
    {
        Window = TimeSpan.FromMinutes(1),
        PermitLimit = permitLimit,
        QueueLimit = 0,
    };
}
