using System.Collections.Concurrent;

namespace BookClubApi.Services;

// Per-user fixed-window rate limit for SignalR hub sends. In-memory because the
// API runs as a single instance; if we ever scale out, swap the dictionary for
// Redis with the same TryAcquire contract.
// TimeProvider rather than DateTime.UtcNow so the window boundary is testable: the only way to
// verify "the 31st send in a minute is refused, but the first send after the window rolls over is
// allowed" against a real clock is to sleep for a minute in a test, which nobody does — so the
// boundary goes unverified. Production passes TimeProvider.System and behaves exactly as before.
public class HubRateLimiter(TimeProvider? timeProvider = null)
{
    private readonly TimeProvider _time = timeProvider ?? TimeProvider.System;

    public const int MaxSendsPerWindow = 30;
    private static readonly TimeSpan Window = TimeSpan.FromMinutes(1);

    private readonly ConcurrentDictionary<Guid, Bucket> _buckets = new();

    private sealed class Bucket
    {
        public DateTime WindowStart;
        public int Count;
    }

    public bool TryAcquire(Guid userId)
    {
        var bucket = _buckets.GetOrAdd(userId, _ => new Bucket { WindowStart = _time.GetUtcNow().UtcDateTime, Count = 0 });
        lock (bucket)
        {
            var now = _time.GetUtcNow().UtcDateTime;
            if (now - bucket.WindowStart >= Window)
            {
                bucket.WindowStart = now;
                bucket.Count = 1;
                return true;
            }
            if (bucket.Count >= MaxSendsPerWindow) return false;
            bucket.Count++;
            return true;
        }
    }

    // Drops every bucket. Only the integration suite calls this: the limiter is a singleton that
    // outlives the per-test database reset, so without it one test's sends would count against
    // the next test's budget and the failure would look like an unrelated 400.
    public void Reset() => _buckets.Clear();
}
