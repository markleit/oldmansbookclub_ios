using System.Collections.Concurrent;
using BookClubApi.Hubs;
using Microsoft.AspNetCore.SignalR;

namespace BookClubApi.Tests.Infrastructure;

/// One recorded SignalR send: which audience it went to, which client method, and the arguments.
/// <paramref name="Target"/> is a readable label like "group:book-<id>" or "user:<guid>".
public record RecordedBroadcast(string Target, string Method, object?[] Args)
{
    public T Arg<T>(int index) => (T)Args[index]!;
}

/// Replaces the real <c>IHubContext&lt;ChatHub&gt;</c> so a test can assert what the server
/// *broadcast*, not just what it stored.
///
/// This is what makes the clientId dedup test meaningful. The bug it guards against is not a
/// duplicate row — the unique index prevents that — it's a duplicate *broadcast and push* for a
/// message that was already delivered. Counting rows would miss it entirely; counting broadcasts
/// is the assertion that actually matches the user-visible failure.
public sealed class RecordingHubContext : IHubContext<ChatHub>
{
    private readonly ConcurrentQueue<RecordedBroadcast> _sends = new();

    public IReadOnlyList<RecordedBroadcast> Sends => [.. _sends];
    public IEnumerable<RecordedBroadcast> OfMethod(string method) => Sends.Where(s => s.Method == method);
    public void Clear() => _sends.Clear();

    public IHubClients Clients { get; }
    public IGroupManager Groups { get; } = new NoOpGroupManager();

    public RecordingHubContext() => Clients = new RecordingClients(_sends);

    private sealed class RecordingClients(ConcurrentQueue<RecordedBroadcast> sends) : IHubClients
    {
        private IClientProxy For(string target) => new RecordingProxy(target, sends);

        public IClientProxy All => For("all");
        public IClientProxy AllExcept(IReadOnlyList<string> excluded) => For($"all-except:{string.Join(',', excluded)}");
        public IClientProxy Client(string connectionId) => For($"connection:{connectionId}");
        public IClientProxy Clients(IReadOnlyList<string> connectionIds) => For($"connections:{string.Join(',', connectionIds)}");
        public IClientProxy Group(string groupName) => For($"group:{groupName}");
        public IClientProxy Groups(IReadOnlyList<string> groupNames) => For($"groups:{string.Join(',', groupNames)}");
        public IClientProxy GroupExcept(string groupName, IReadOnlyList<string> excluded) => For($"group:{groupName}-except:{string.Join(',', excluded)}");
        public IClientProxy User(string userId) => For($"user:{userId}");
        public IClientProxy Users(IReadOnlyList<string> userIds) => For($"users:{string.Join(',', userIds)}");
    }

    private sealed class RecordingProxy(string target, ConcurrentQueue<RecordedBroadcast> sends) : IClientProxy
    {
        public Task SendCoreAsync(string method, object?[] args, CancellationToken cancellationToken = default)
        {
            sends.Enqueue(new RecordedBroadcast(target, method, args));
            return Task.CompletedTask;
        }
    }

    private sealed class NoOpGroupManager : IGroupManager
    {
        public Task AddToGroupAsync(string connectionId, string groupName, CancellationToken cancellationToken = default) => Task.CompletedTask;
        public Task RemoveFromGroupAsync(string connectionId, string groupName, CancellationToken cancellationToken = default) => Task.CompletedTask;
    }
}
