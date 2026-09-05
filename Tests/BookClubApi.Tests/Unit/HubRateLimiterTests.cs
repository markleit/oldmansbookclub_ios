using BookClubApi.Services;
using Microsoft.Extensions.Time.Testing;

namespace BookClubApi.Tests.Unit;

/// Pure unit tests — no host, no database. The window boundary is the interesting part, and it is
/// only reachable at all because HubRateLimiter takes a TimeProvider; against the real clock the
/// only way to test the rollover would be to sleep for a minute, which means in practice it would
/// never be tested.
public class HubRateLimiterTests
{
    [Fact]
    public void Allows_exactly_thirty_sends_in_a_window()
    {
        var limiter = new HubRateLimiter(new FakeTimeProvider());
        var user = Guid.NewGuid();

        for (var i = 0; i < HubRateLimiter.MaxSendsPerWindow; i++)
            Assert.True(limiter.TryAcquire(user), $"send {i + 1} should have been allowed");

        Assert.False(limiter.TryAcquire(user));
    }

    [Fact]
    public void The_window_rolls_over_after_a_minute()
    {
        var clock = new FakeTimeProvider();
        var limiter = new HubRateLimiter(clock);
        var user = Guid.NewGuid();

        for (var i = 0; i < HubRateLimiter.MaxSendsPerWindow; i++) limiter.TryAcquire(user);
        Assert.False(limiter.TryAcquire(user));

        clock.Advance(TimeSpan.FromSeconds(60));

        Assert.True(limiter.TryAcquire(user));
    }

    [Fact]
    public void The_window_has_not_rolled_over_a_moment_before_the_minute()
    {
        var clock = new FakeTimeProvider();
        var limiter = new HubRateLimiter(clock);
        var user = Guid.NewGuid();

        for (var i = 0; i < HubRateLimiter.MaxSendsPerWindow; i++) limiter.TryAcquire(user);

        clock.Advance(TimeSpan.FromSeconds(59.9));

        Assert.False(limiter.TryAcquire(user));
    }

    [Fact]
    public void Buckets_are_per_user()
    {
        var limiter = new HubRateLimiter(new FakeTimeProvider());
        var noisy = Guid.NewGuid();
        var quiet = Guid.NewGuid();

        for (var i = 0; i < HubRateLimiter.MaxSendsPerWindow; i++) limiter.TryAcquire(noisy);
        Assert.False(limiter.TryAcquire(noisy));

        // One member hitting the limit must not mute everyone else in the club.
        Assert.True(limiter.TryAcquire(quiet));
    }

    [Fact]
    public void Reset_clears_every_bucket()
    {
        var limiter = new HubRateLimiter(new FakeTimeProvider());
        var user = Guid.NewGuid();
        for (var i = 0; i < HubRateLimiter.MaxSendsPerWindow; i++) limiter.TryAcquire(user);

        limiter.Reset();

        Assert.True(limiter.TryAcquire(user));
    }
}
