using System.Net;

namespace BookClubApi.Tests.Infrastructure;

/// Intercepts an outbound HttpClient so tests never reach a third party. Used for the named
/// "apns", "github" and "google-books" clients.
///
/// It records requests rather than merely blocking them, which is the point: real APNs delivery
/// can't be tested without a device, but the payload the server *builds* — alert text, badge
/// count, per-book unread, apns-topic — is pure server logic and is exactly the kind of thing that
/// silently regresses. Recording it turns half of push into a normal assertion.
public sealed class StubHttpHandler : HttpMessageHandler
{
    private readonly List<(HttpRequestMessage Request, string Body)> _requests = [];
    private readonly Lock _gate = new();

    /// Overridable per test; defaults to APNs' success shape (200, empty body).
    public Func<HttpRequestMessage, string, HttpResponseMessage> Responder { get; set; } =
        (_, _) => new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent("") };

    /// Google Books' answer for a query that matched nothing (200, no "items").
    public static readonly Func<HttpRequestMessage, string, HttpResponseMessage> NoGoogleBooksMatches =
        (_, _) => new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent("""{"kind":"books#volumes","totalItems":0}""") };

    public IReadOnlyList<(HttpRequestMessage Request, string Body)> Requests
    {
        get { lock (_gate) return [.. _requests]; }
    }

    public void Clear() { lock (_gate) _requests.Clear(); }

    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        // Read the body before responding — the caller disposes the request afterwards, and a
        // test asserting on the payload would otherwise find it gone.
        var body = request.Content is null ? "" : await request.Content.ReadAsStringAsync(cancellationToken);
        lock (_gate) _requests.Add((request, body));
        return Responder(request, body);
    }
}
