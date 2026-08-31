using System.Threading.Channels;
using BookClubApi.Data;
using BookClubApi.Models;
using Microsoft.EntityFrameworkCore;

namespace BookClubApi.Services;

// #24 — a new-message push job handed off from the hub so the sender's invoke() returns without
// waiting on the per-member badge queries + APNs round-trips.
// SenderDeviceToken (#25) — the token of the specific device that sent this message, if the hub
// connection supplied one; null for a connection that didn't (e.g. an unupdated client). Lets the
// fan-out exclude only that one device instead of every device the sender owns.
public record NotificationJob(Guid BookId, MessageDto Dto, string BookTitle, string? SenderDeviceToken);

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

    // #25 — per-device fan-out: send to every device in the club except the one that sent this
    // message (not every device the sender owns — a multi-device user's other devices SHOULD get
    // pushed for their own message, same as any other member's).
    private async Task DispatchAsync(NotificationJob job, CancellationToken ct)
    {
        using var scope = scopeFactory.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
        var dto = job.Dto;

        // A connection that didn't supply a device id (an unupdated client) can't be pinpointed to
        // one device, so fall back to excluding the whole sender — today's behavior — rather than
        // risk pushing the message straight back to whichever device sent it.
        var recipients = await db.Memberships
            .Where(m => m.ClubId == dto.ClubId)
            .Where(m => job.SenderDeviceToken != null || m.UserId != dto.SenderId)
            .SelectMany(m => db.UserDevices.Where(d => d.UserId == m.UserId),
                (m, d) => new { m.UserId, d.DeviceToken })
            .Where(x => x.DeviceToken != job.SenderDeviceToken)
            .Distinct()
            .ToListAsync(ct);

        foreach (var group in recipients.GroupBy(r => r.UserId))
        {
            var (badge, perBook) = await UnreadCalculator.TotalWithPerBookAsync(db, group.Key);
            var tokens = group.Select(r => r.DeviceToken).ToList();
            await notifications.SendNewMessageAsync(tokens, dto, job.BookTitle, job.BookId, badge,
                perBook.GetValueOrDefault(job.BookId));
        }
    }
}
