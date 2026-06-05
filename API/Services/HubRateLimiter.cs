using System.Collections.Concurrent;

namespace BookClubApi.Services;

// Per-user fixed-window rate limit for SignalR hub sends. In-memory because the
// API runs as a single instance; if we ever scale out, swap the dictionary for
// Redis with the same TryAcquire contract.
public class HubRateLimiter
{
    private const int MaxSendsPerWindow = 30;
    private static readonly TimeSpan Window = TimeSpan.FromMinutes(1);

    private readonly ConcurrentDictionary<Guid, Bucket> _buckets = new();

    private sealed class Bucket
    {
        public DateTime WindowStart;
        public int Count;
    }

    public bool TryAcquire(Guid userId)
    {
        var bucket = _buckets.GetOrAdd(userId, _ => new Bucket { WindowStart = DateTime.UtcNow, Count = 0 });
        lock (bucket)
        {
            var now = DateTime.UtcNow;
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
}
