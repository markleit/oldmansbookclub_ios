using System.Security.Cryptography;
using BookClubApi.Data;
using BookClubApi.Hubs;
using BookClubApi.Services;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.AspNetCore.TestHost;
using Microsoft.AspNetCore.SignalR;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Options;
using Microsoft.AspNetCore.RateLimiting;
using System.Threading.RateLimiting;

namespace BookClubApi.Tests.Infrastructure;

/// Boots the real API — the actual Program.cs pipeline, controllers, auth, EF model and startup
/// migration — against the container database, with only the genuinely external edges replaced.
///
/// What is deliberately NOT replaced: the database (real SQL Server), the JWT pipeline (tests mint
/// real tokens against a test secret), rate limiting, model binding and the JSON options. Those
/// are the layers regressions actually hide in.
public sealed class ApiFactory : WebApplicationFactory<Program>
{
    private readonly SqlServerFixture _sql;

    public ApiFactory(SqlServerFixture sql)
    {
        _sql = sql;
        // Environment variables, NOT ConfigureAppConfiguration — and this is a trap worth the
        // paragraph. Program.cs reads Jwt:Secret EAGERLY at line ~104 (`?? throw`) while building
        // the host. WebApplicationFactory's ConfigureAppConfiguration callbacks are applied to the
        // builder AFTER Program's own top-level statements have run, so by the time the test's
        // values land, the JWT signing key has already been captured from whatever the developer
        // has in `dotnet user-secrets`. The symptom is superb: the app happily mints tokens with
        // the test secret and validates them against the dev secret, and every authenticated
        // request 401s with "The signature key was not found" while a config dump shows the
        // correct values everywhere.
        //
        // WebApplication.CreateBuilder layers environment variables AFTER user secrets and before
        // Program runs, so setting them here is both early enough and high-enough precedence.
        foreach (var (key, value) in Settings)
            Environment.SetEnvironmentVariable(key.Replace(":", "__"), value);
    }

    private Dictionary<string, string?> Settings => new()
    {
        ["ConnectionStrings:DefaultConnection"] = _sql.ConnectionString,
        ["Jwt:Secret"] = JwtSecret,
        ["Jwt:Issuer"] = JwtIssuer,
        ["Jwt:Audience"] = JwtAudience,
        ["Apns:KeyId"] = "TESTKEYID1",
        ["Apns:TeamId"] = "TESTTEAMID",
        ["Apns:PrivateKey"] = ApnsTestKey,
        ["Apple:BundleId"] = "com.markleit.oldmansbookclub",
        ["Demo:Passphrase"] = DemoPassphrase,
        ["Seeding:Key"] = SeedingKey,
        ["GitHub:Token"] = "test-github-token",
        // Explicit rather than relying on the default: a developer's user-secrets sets this false
        // (#120 — dev must never push real devices), and inheriting that would silently disable
        // every push assertion in the suite while the tests still went green.
        ["Apns:Enabled"] = "true",
    };

    /// A throwaway P-256 key so NotificationService can build a real APNs JWT. Generated per run
    /// rather than committed — a checked-in .p8, even a fake one, is a thing someone eventually
    /// mistakes for a real credential.
    private static readonly string ApnsTestKey =
        Convert.ToBase64String(ECDsa.Create(ECCurve.NamedCurves.nistP256).ExportPkcs8PrivateKey());

    public const string JwtSecret = "test-only-signing-key-do-not-use-anywhere-else-0123456789";
    public const string JwtIssuer = "https://test.oldmansbookclub.local";
    public const string JwtAudience = "com.markleit.oldmansbookclub.tests";
    public const string SeedingKey = "test-seed-key";
    public const string DemoPassphrase = "test-demo-passphrase";

    public FakeBlobService Blob { get; } = new();
    public RecordingHubContext Hub { get; } = new();
    public StubHttpHandler Apns { get; } = new();
    public StubHttpHandler GitHub { get; } = new();

    protected override void ConfigureWebHost(IWebHostBuilder builder)
    {
        // "Development" and not a bespoke "Testing": Program.cs branches on IsDevelopment() to run
        // SignalR in-process instead of reaching Azure SignalR, and the seed endpoints
        // (/admin/seed-baseline, used by the UI-test lanes) 404 outside Development. Testing the
        // app in a mode it never actually runs in would defeat the point.
        builder.UseEnvironment(Environments.Development);

        builder.ConfigureTestServices(services =>
        {
            services.RemoveAll<BlobService>();
            services.AddSingleton<BlobService>(Blob);

            services.RemoveAll<AppleTokenValidator>();
            services.AddScoped<AppleTokenValidator>(_ => new FakeAppleTokenValidator());

            services.RemoveAll<IHubContext<ChatHub>>();
            services.AddSingleton<IHubContext<ChatHub>>(Hub);

            // The dispatch worker drains NotificationQueue on a background thread. Removing it
            // makes push assertions deterministic: a test can read the queue and know exactly what
            // the send path enqueued, with no sleep-and-hope. PushDispatchTests puts it back for
            // the one case that needs the fan-out itself under test.
            services.RemoveAll<IHostedService>();

            // The /auth/* endpoints are rate limited to 10 requests per minute — and the limiter
            // is declared with NO partition key, so that is 10 per minute for the entire process,
            // not per IP or per user. One shared test host therefore exhausts it after ten auth
            // calls and every later test 429s, in whatever order they happen to run.
            //
            // Tests run with permissive limits instead. The limits themselves are asserted
            // separately: HubRateLimiterTests covers the send limiter (the one with real
            // per-user semantics), and the auth limiter is exercised end-to-end by the live lane.
            //
            // Worth noting the finding rather than burying it: a global partition means a single
            // client retrying a failed sign-in can lock every other member out of signing in for
            // up to a minute. That is a production behaviour question, not a test-suite one.
            services.RemoveAll<IConfigureOptions<RateLimiterOptions>>();
            services.AddRateLimiter(options =>
            {
                options.RejectionStatusCode = 429;
                options.AddFixedWindowLimiter("auth", o => { o.Window = TimeSpan.FromMinutes(1); o.PermitLimit = int.MaxValue; o.QueueLimit = 0; });
                options.AddFixedWindowLimiter("media", o => { o.Window = TimeSpan.FromMinutes(1); o.PermitLimit = int.MaxValue; o.QueueLimit = 0; });
            });

            services.AddHttpClient("apns").ConfigurePrimaryHttpMessageHandler(() => Apns);
            services.AddHttpClient("apns-sandbox").ConfigurePrimaryHttpMessageHandler(() => Apns);
            services.AddHttpClient("github").ConfigurePrimaryHttpMessageHandler(() => GitHub);
        });
    }

    /// Forces the host to build (running Program.cs's startup migration against the empty
    /// container database) and then hands Respawn a migrated schema to snapshot.
    public async Task EnsureMigratedAsync()
    {
        using var scope = Services.CreateScope();
        await scope.ServiceProvider.GetRequiredService<AppDbContext>().Database.CanConnectAsync();
        await _sql.InitializeRespawnAsync();
    }

    public AppDbContext NewDbContext()
    {
        var options = new DbContextOptionsBuilder<AppDbContext>().UseSqlServer(_sql.ConnectionString).Options;
        return new AppDbContext(options);
    }
}

/// Sign in with Apple, minus Apple. Returns whatever the test told it to.
public sealed class FakeAppleTokenValidator() : AppleTokenValidator(new NullHttpClientFactory(), EmptyConfiguration(), NullLogger)
{
    public static (string Subject, string MatchedBundleId)? NextResult { get; set; } =
        ("apple_test_subject", "com.markleit.oldmansbookclub");

    public override Task<(string Subject, string MatchedBundleId)?> ValidateAsync(string identityToken, IReadOnlyList<string> validAudiences)
        => Task.FromResult(NextResult);

    public override Task<string?> ExchangeCodeForRefreshTokenAsync(string authorizationCode, string bundleId)
        => Task.FromResult<string?>("fake-apple-refresh-token");

    public override Task RevokeRefreshTokenAsync(string refreshToken, string bundleId) => Task.CompletedTask;

    private static Microsoft.Extensions.Logging.ILogger<AppleTokenValidator> NullLogger =>
        Microsoft.Extensions.Logging.Abstractions.NullLogger<AppleTokenValidator>.Instance;

    private sealed class NullHttpClientFactory : IHttpClientFactory
    {
        public HttpClient CreateClient(string name) => new(new StubHttpHandler());
    }

    private static Microsoft.Extensions.Configuration.IConfiguration EmptyConfiguration() =>
        new Microsoft.Extensions.Configuration.ConfigurationBuilder().Build();
}
