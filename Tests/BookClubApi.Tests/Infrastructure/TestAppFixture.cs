namespace BookClubApi.Tests.Infrastructure;

/// Assembly-wide fixture: one SQL Server container, one booted API host, shared by every
/// integration test. Starting a container per test class would add roughly a minute each; the
/// per-test isolation comes from Respawn instead (see <see cref="SqlServerFixture.ResetAsync"/>).
public sealed class TestAppFixture : IAsyncLifetime
{
    public SqlServerFixture Sql { get; } = new();
    public ApiFactory App { get; private set; } = null!;

    public async Task InitializeAsync()
    {
        await Sql.StartAsync();
        App = new ApiFactory(Sql);
        // Building the host runs Program.cs's startup migration against the empty container
        // database — so all 33 migrations execute for real on every CI run. A migration that only
        // works against an already-populated schema fails here, which is the point.
        await App.EnsureMigratedAsync();
    }

    public async Task DisposeAsync()
    {
        await App.DisposeAsync();
        await Sql.StopAsync();
    }
}

/// Every integration test class joins this collection, which serialises them. They share one
/// database, and a test that starts mid-reset of another would be flaky in a way that is
/// miserable to debug. Suite runtime is dominated by container startup, not by the tests, so
/// serialising costs little.
[CollectionDefinition(Name)]
public sealed class IntegrationCollection : ICollectionFixture<TestAppFixture>
{
    public const string Name = "integration";
}
