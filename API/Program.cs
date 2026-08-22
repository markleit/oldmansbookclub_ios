using System.Text;
using System.Threading.RateLimiting;
using Azure.Identity;
using BookClubApi.Data;
using BookClubApi.Hubs;
using BookClubApi.Services;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.AspNetCore.RateLimiting;
using Microsoft.EntityFrameworkCore;
using Microsoft.IdentityModel.Tokens;

var builder = WebApplication.CreateBuilder(args);

builder.Services.AddControllers()
    .AddJsonOptions(options =>
    {
        options.JsonSerializerOptions.PropertyNamingPolicy = System.Text.Json.JsonNamingPolicy.SnakeCaseLower;
        options.JsonSerializerOptions.PropertyNameCaseInsensitive = true;
        options.JsonSerializerOptions.Converters.Add(new System.Text.Json.Serialization.JsonStringEnumConverter());
        options.JsonSerializerOptions.Converters.Add(new UtcDateTimeConverter());
    });
builder.Services.AddEndpointsApiExplorer();
builder.Services.AddSwaggerGen();
builder.Services.AddHttpClient();

// Database
builder.Services.AddDbContext<AppDbContext>(options =>
    options.UseSqlServer(builder.Configuration.GetConnectionString("DefaultConnection"),
        sql => sql.EnableRetryOnFailure(maxRetryCount: 5, maxRetryDelay: TimeSpan.FromSeconds(10), errorNumbersToAdd: null)));

builder.Services.AddHealthChecks()
    .AddDbContextCheck<AppDbContext>("database", tags: ["ready"]);

// SignalR. Production uses the Azure SignalR Service backplane (needed across
// multiple App Service instances). Development runs in-process instead (#120 half A) —
// this used to be shared with prod so a simulator and a physical device (which was
// PREVIOUSLY FORCED onto production, see #120 half B) could reach each other in real
// time. That constraint is gone: a device can now point at this same local process, so
// in-process SignalR still gives sim<->device real-time (both connect to one server),
// while guaranteeing every hub invoke is actually visible here, and touching no Azure
// SignalR resource for dev traffic at all.
var signalR = builder.Services.AddSignalR()
    .AddJsonProtocol(options =>
    {
        options.PayloadSerializerOptions.PropertyNamingPolicy = System.Text.Json.JsonNamingPolicy.CamelCase;
        options.PayloadSerializerOptions.Converters.Add(new System.Text.Json.Serialization.JsonStringEnumConverter());
        options.PayloadSerializerOptions.Converters.Add(new UtcDateTimeConverter());
    });
if (!builder.Environment.IsDevelopment())
{
    signalR.AddAzureSignalR(builder.Configuration["Azure:SignalRConnectionString"]
        ?? "Endpoint=https://oldmansbookclub-signalr.service.signalr.net;AuthType=aad;Version=1.0;");
}

// Services
builder.Services.AddScoped<AppleTokenValidator>();
builder.Services.AddSingleton<BlobService>();
builder.Services.AddSingleton<NotificationService>();
builder.Services.AddSingleton<NotificationQueue>();               // #24
builder.Services.AddHostedService<NotificationDispatchService>();  // #24
builder.Services.AddSingleton<HubRateLimiter>();
builder.Services.AddSingleton<GitHubService>();
builder.Services.AddHttpClient("github", client =>
{
    client.BaseAddress = new Uri("https://api.github.com/");
    var token = builder.Configuration["GitHub:Token"];
    if (!string.IsNullOrWhiteSpace(token))
        client.DefaultRequestHeaders.Authorization =
            new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", token);
    client.DefaultRequestHeaders.Accept.Add(
        new System.Net.Http.Headers.MediaTypeWithQualityHeaderValue("application/vnd.github+json"));
    client.DefaultRequestHeaders.UserAgent.ParseAdd("oldmansbookclub-api");
    client.DefaultRequestHeaders.Add("X-GitHub-Api-Version", "2022-11-28");
});
builder.Services.AddHttpClient("apns", client =>
{
    client.BaseAddress = new Uri("https://api.push.apple.com");
    client.DefaultRequestVersion = System.Net.HttpVersion.Version20;
    client.DefaultVersionPolicy = System.Net.Http.HttpVersionPolicy.RequestVersionOrHigher;
}).ConfigurePrimaryHttpMessageHandler(() => new SocketsHttpHandler
{
    // Send HTTP/2 PING frames every 90s to prevent APNs from closing idle connections
    KeepAlivePingDelay = TimeSpan.FromSeconds(90),
    KeepAlivePingTimeout = TimeSpan.FromSeconds(30),
    KeepAlivePingPolicy = HttpKeepAlivePingPolicy.Always,
    // Proactively close connections idle longer than 4 min (APNs closes at ~5 min)
    PooledConnectionIdleTimeout = TimeSpan.FromMinutes(4),
});
builder.Services.AddHttpClient("apns-sandbox", client =>
{
    client.BaseAddress = new Uri("https://api.sandbox.push.apple.com");
    client.DefaultRequestVersion = System.Net.HttpVersion.Version20;
    client.DefaultVersionPolicy = System.Net.Http.HttpVersionPolicy.RequestVersionOrHigher;
}).ConfigurePrimaryHttpMessageHandler(() => new SocketsHttpHandler
{
    KeepAlivePingDelay = TimeSpan.FromSeconds(90),
    KeepAlivePingTimeout = TimeSpan.FromSeconds(30),
    KeepAlivePingPolicy = HttpKeepAlivePingPolicy.Always,
    PooledConnectionIdleTimeout = TimeSpan.FromMinutes(4),
});

// JWT Auth
var jwtKey = builder.Configuration["Jwt:Secret"]
    ?? throw new InvalidOperationException("Jwt:Secret not configured");

builder.Services.AddAuthentication(JwtBearerDefaults.AuthenticationScheme)
    .AddJwtBearer(options =>
    {
        options.MapInboundClaims = false;
        options.TokenValidationParameters = new TokenValidationParameters
        {
            ValidateIssuer = true,
            ValidateAudience = true,
            ValidateLifetime = true,
            ValidateIssuerSigningKey = true,
            ValidIssuer = builder.Configuration["Jwt:Issuer"],
            ValidAudience = builder.Configuration["Jwt:Audience"],
            IssuerSigningKey = new SymmetricSecurityKey(Encoding.UTF8.GetBytes(jwtKey))
        };
        // Allow JWT via query string for SignalR WebSocket connections
        options.Events = new JwtBearerEvents
        {
            OnMessageReceived = ctx =>
            {
                var token = ctx.Request.Query["access_token"];
                if (!string.IsNullOrEmpty(token) &&
                    ctx.HttpContext.Request.Path.StartsWithSegments("/hubs"))
                    ctx.Token = token;
                return Task.CompletedTask;
            }
        };
    });

builder.Services.AddAuthorization();

builder.Services.AddRateLimiter(options =>
{
    options.RejectionStatusCode = 429;
    // Auth endpoints: 10 attempts per minute per IP
    options.AddFixedWindowLimiter("auth", o =>
    {
        o.Window = TimeSpan.FromMinutes(1);
        o.PermitLimit = 10;
        o.QueueLimit = 0;
    });
    // Media upload-url endpoints: 30 per minute per user
    options.AddFixedWindowLimiter("media", o =>
    {
        o.Window = TimeSpan.FromMinutes(1);
        o.PermitLimit = 30;
        o.QueueLimit = 0;
    });
});

var app = builder.Build();

if (app.Environment.IsDevelopment())
{
    app.UseSwagger();
    app.UseSwaggerUI();
}

app.UseRateLimiter();
app.UseAuthentication();
app.UseAuthorization();
app.MapControllers();
app.MapHub<ChatHub>("/hubs/chat");

// Liveness — no dependencies. App Service / orchestrators use this to know the process is up.
app.MapGet("/health", () => Results.Ok("healthy"));
// Readiness — fails 503 if the DB is unreachable. Use for traffic gating.
app.MapHealthChecks("/health/ready");

// Run migrations synchronously before serving traffic. Fail-fast so a bad migration
// doesn't leave the app reporting healthy with the wrong schema.
using (var scope = app.Services.CreateScope())
{
    var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
    var logger = scope.ServiceProvider.GetRequiredService<ILogger<AppDbContext>>();
    try
    {
        await db.Database.MigrateAsync();
        logger.LogInformation("Database migration completed successfully.");
    }
    catch (Exception ex)
    {
        logger.LogCritical(ex, "Database migration failed — aborting startup.");
        throw;
    }
}

app.Run();
