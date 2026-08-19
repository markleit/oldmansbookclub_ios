using System.Threading.Channels;
using BookClubApi.Data;
using BookClubApi.Models;
using Microsoft.EntityFrameworkCore;

namespace BookClubApi.Services;

// #24 — a new-message push job handed off from the hub so the sender's invoke() returns without
// waiting on the per-member badge queries + APNs round-trips.
public record NotificationJob(Guid BookId, MessageDto Dto, string BookTitle);

// Singleton mailbox between the hub (producer) and the dispatch worker (consumer). TryWrite never
// blocks the hub; a book club's send rate can't realistically back this up.
public class NotificationQueue
{
    private readonly Channel<NotificationJob> _channel =
        Channel.CreateUnbounded<NotificationJob>(new UnboundedChannelOptions { SingleReader = true });

    public void Enqueue(NotificationJob job) => _channel.Writer.TryWrite(job);
    public ChannelReader<NotificationJob> Reader => _channel.Reader;
}

// Hosted worker that drains the queue and fans out APNs pushes on ITS OWN DI scope. The hub's
// scoped DbContext is disposed the moment the hub method returns, so the fan-out (moved here out
// of ChatHub.BroadcastAndNotify) must not reuse it — it creates a fresh scope per job (#24).
public class NotificationDispatchService(
    IServiceScopeFactory scopeFactory,
    NotificationQueue queue,
    NotificationService notifications,
    ILogger<NotificationDispatchService> logger) : BackgroundService
{
    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        await foreach (var job in queue.Reader.ReadAllAsync(stoppingToken))
        {
            try { await DispatchAsync(job, stoppingToken); }
            catch (Exception ex) { logger.LogError(ex, "[NotificationDispatch] failed for book {BookId}", job.BookId); }
        }
    }

    // Same fan-out that used to run inline in the hub: exclude the sender's own device token(s),
    // dedupe shared tokens, and send each recipient their own unread badge total.
    private async Task DispatchAsync(NotificationJob job, CancellationToken ct)
    {
        using var scope = scopeFactory.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
        var dto = job.Dto;

        var senderTokens = await db.Users
            .Where(u => u.Id == dto.SenderId && u.DeviceToken != null)
            .Select(u => u.DeviceToken!)
            .ToListAsync(ct);

        var recipients = await db.Memberships
            .Where(m => m.ClubId == dto.ClubId && m.UserId != dto.SenderId && m.User.DeviceToken != null)
            .Select(m => new { m.UserId, Token = m.User.DeviceToken! })
            .Distinct()
            .ToListAsync(ct);

        var seenTokens = new HashSet<string>(senderTokens);
        foreach (var r in recipients)
        {
            if (!seenTokens.Add(r.Token)) continue;   // skip sender's device + dupes
            var badge = await UnreadCalculator.TotalAsync(db, r.UserId);
            await notifications.SendNewMessageAsync([r.Token], dto, job.BookTitle, job.BookId, badge);
        }
    }
}
