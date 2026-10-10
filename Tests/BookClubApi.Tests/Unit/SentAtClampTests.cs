using BookClubApi.Services;

namespace BookClubApi.Tests.Unit;

/// #204 — the sender's "tapped Send at" time orders the chat, so it's clamped: never after the
/// server received it, never more than 7 days before. Pure — the endpoint tests cover the wiring.
public class SentAtClampTests
{
    private static readonly DateTime Received = new(2026, 10, 10, 12, 0, 0, DateTimeKind.Utc);

    [Fact]
    public void No_time_from_the_client_means_the_arrival_time() =>
        Assert.Equal(Received, MessageSendService.ClampSentAt(null, Received));

    [Fact]
    public void A_time_inside_the_window_is_kept_exactly() =>
        Assert.Equal(Received.AddHours(-3), MessageSendService.ClampSentAt(Received.AddHours(-3), Received));

    [Fact]
    public void A_time_after_arrival_is_pulled_back_to_arrival() =>
        // A phone whose clock runs fast must not put its message below ones sent after it.
        Assert.Equal(Received, MessageSendService.ClampSentAt(Received.AddMinutes(5), Received));

    [Fact]
    public void A_time_older_than_seven_days_is_pulled_forward_to_seven_days() =>
        Assert.Equal(Received.AddDays(-7), MessageSendService.ClampSentAt(Received.AddDays(-400), Received));

    [Fact]
    public void Exactly_seven_days_is_still_inside_the_window() =>
        Assert.Equal(Received.AddDays(-7), MessageSendService.ClampSentAt(Received.AddDays(-7), Received));

    [Fact]
    public void A_local_time_is_compared_as_the_instant_it_represents()
    {
        var local = Received.AddHours(-1).ToLocalTime();
        Assert.Equal(Received.AddHours(-1), MessageSendService.ClampSentAt(local, Received));
    }
}
