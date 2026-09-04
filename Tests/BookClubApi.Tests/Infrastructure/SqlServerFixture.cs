using System.Data.Common;
using System.Runtime.InteropServices;
using DotNet.Testcontainers.Builders;
using Microsoft.Data.SqlClient;
using Respawn;
using Testcontainers.MsSql;

namespace BookClubApi.Tests.Infrastructure;

/// One throwaway SQL Server for the whole test assembly.
///
/// This is the load-bearing choice of the suite. SQLite and the EF in-memory provider are both
/// unusable here: <c>AppDbContext</c> declares the unique index on (SenderId, ClientId) with a
/// T-SQL filter (<c>"[ClientId] IS NOT NULL"</c>), eight migrations contain raw T-SQL, and
/// <c>MessageSendService.IsUniqueClientIdViolation</c> inspects <c>SqlException.Number</c> for
/// 2601/2627. On any other provider the clientId dedup tests would pass while enforcing nothing —
/// green, and testing the opposite of what they claim.
///
/// Running the container also answers #126's three open questions at once: the runner reaches it
/// over loopback (no Azure SQL firewall rule for a non-static GitHub egress IP), it starts empty
/// every run (deterministic state), and two concurrent CI runs each get their own (no collision).
public sealed class SqlServerFixture
{
    /// The real SQL Server image, used by CI (and any amd64 host). Pinned rather than :latest —
    /// a silent server-version bump is exactly the kind of thing that turns a red CI run into an
    /// afternoon of confusion.
    public const string SqlServerImage = "mcr.microsoft.com/mssql/server:2022-CU14-ubuntu-22.04";

    /// Apple Silicon fallback. `mssql/server` publishes no arm64 image, and the amd64 one does not
    /// run under Rosetta either — it aborts at startup with "Invalid mapping of address ... in
    /// reserved address space", because SQL Server requires a virtual-address layout Rosetta does
    /// not provide. Azure SQL Edge ships a native arm64 image on the same engine and supports
    /// everything this schema needs: filtered indexes with a T-SQL predicate, ROW_NUMBER, NEWID,
    /// GETUTCDATE, and unique-violation errors 2601/2627.
    ///
    /// This is a real (if narrow) divergence: a developer on an M-series Mac and CI are not running
    /// byte-identical servers. It is the only lane in the suite where that is true, CI runs the
    /// real image on every PR, and the alternative — no local runs at all on the primary dev
    /// machine — is worse. Override with OMBC_TEST_SQL_IMAGE to force either one.
    public const string ArmFallbackImage = "mcr.microsoft.com/azure-sql-edge:latest";

    public static string Image =>
        Environment.GetEnvironmentVariable("OMBC_TEST_SQL_IMAGE")
        ?? (RuntimeInformation.ProcessArchitecture == Architecture.Arm64 ? ArmFallbackImage : SqlServerImage);

    private readonly MsSqlContainer _container = new MsSqlBuilder(Image)
        // The default wait strategy shells out to sqlcmd, which the Azure SQL Edge image does not
        // ship. Waiting on the port and then proving a real connection opens (below) works for
        // both images.
        .WithWaitStrategy(Wait.ForUnixContainer().UntilInternalTcpPortIsAvailable(MsSqlBuilder.MsSqlPort))
        .Build();

    private Respawner? _respawner;
    private DbConnection? _respawnConnection;

    /// Points at a database named by us rather than the container's default, so the app's own
    /// startup migration path (Program.cs) is what creates the schema — migrations are under test,
    /// not bypassed by an EnsureCreated shortcut.
    public string ConnectionString { get; private set; } = "";

    public async Task StartAsync()
    {
        await _container.StartAsync();
        ConnectionString = new SqlConnectionStringBuilder(_container.GetConnectionString())
        {
            InitialCatalog = "ombc_test",
            TrustServerCertificate = true
        }.ConnectionString;
        await WaitForServerAsync();
    }

    /// The port opens before the engine finishes recovery, so a connection attempt right after
    /// UntilPortIsAvailable can still be refused. Poll until one actually succeeds, otherwise the
    /// first test run on a cold machine fails for a reason that has nothing to do with the code.
    private async Task WaitForServerAsync()
    {
        var master = new SqlConnectionStringBuilder(ConnectionString) { InitialCatalog = "master" }.ConnectionString;
        var deadline = DateTime.UtcNow.AddMinutes(3);
        while (true)
        {
            try
            {
                await using var connection = new SqlConnection(master);
                await connection.OpenAsync();
                return;
            }
            catch (SqlException) when (DateTime.UtcNow < deadline)
            {
                await Task.Delay(TimeSpan.FromSeconds(2));
            }
        }
    }

    /// Called once by ApiFactory after the host has migrated the schema — Respawn has to inspect
    /// tables that don't exist until then.
    public async Task InitializeRespawnAsync()
    {
        if (_respawner is not null) return;
        _respawnConnection = new SqlConnection(ConnectionString);
        await _respawnConnection.OpenAsync();
        _respawner = await Respawner.CreateAsync(_respawnConnection, new RespawnerOptions
        {
            // Deleting this would make the next test run re-apply all 33 migrations onto a schema
            // that already has them.
            TablesToIgnore = [new Respawn.Graph.Table("__EFMigrationsHistory")]
        });
    }

    /// Empties every table. Called before each test so no test can depend on another's leftovers —
    /// the failure mode that made the existing UI tests flaky as bookclubdb-dev accumulated rows.
    public async Task ResetAsync()
    {
        if (_respawner is null || _respawnConnection is null)
            throw new InvalidOperationException("InitializeRespawnAsync must run first.");
        await _respawner.ResetAsync(_respawnConnection);
    }

    public async Task StopAsync()
    {
        if (_respawnConnection is not null) await _respawnConnection.DisposeAsync();
        await _container.DisposeAsync();
    }
}
