using Microsoft.AspNetCore.Mvc.Filters;
using Microsoft.AspNetCore.Server.Kestrel.Core.Features;

namespace BookClubApi.Services;

/// #204 — turns off Kestrel's minimum upload speed for one endpoint.
///
/// By default Kestrel cuts off a request whose body arrives slower than 240 bytes/s once a 5 s grace
/// period has passed — a guard against clients that open a request and stop sending. A batch of
/// photos breaks that assumption: the phone sends them all over one connection, and an upload
/// waiting its turn behind the others receives nothing for longer than the grace period. It isn't
/// slow, it's queued. The 2.2 (2) device pass saw it on a fast connection: 2 of 9 uploads cut off
/// (408, a 502 at the App Service front end) and sent again. Ten photos on an ordinary cellular
/// uplink take 10–20 s to drain, so most of a batch would be cut off, every round.
///
/// The endpoint keeps its other limits: sign-in, the per-member send limit, the size cap, and the
/// App Service front end's ~230 s limit on any request — so a client that stops sending still
/// can't hold the connection for long.
[AttributeUsage(AttributeTargets.Method)]
public sealed class NoMinimumUploadSpeedAttribute : Attribute, IResourceFilter
{
    // A resource filter runs before model binding, so before anything reads the body.
    public void OnResourceExecuting(ResourceExecutingContext context)
    {
        // Absent off Kestrel (the in-memory test server).
        var feature = context.HttpContext.Features.Get<IHttpMinRequestBodyDataRateFeature>();
        if (feature is null) return;
        try
        {
            feature.MinDataRate = null;
        }
        catch (NotSupportedException)
        {
            // HTTP/2 straight to Kestrel can't change it per request. In production the front end
            // talks HTTP/1.1 to the app, so this is local development only.
        }
    }

    public void OnResourceExecuted(ResourceExecutedContext context) { }
}
