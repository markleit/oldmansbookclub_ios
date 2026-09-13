using System.IdentityModel.Tokens.Jwt;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Security.Claims;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using BookClubApi.Data;
using BookClubApi.Models;
using BookClubApi.Services;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.IdentityModel.Tokens;

namespace BookClubApi.Tests.Infrastructure;

/// A seeded user plus a client already carrying their bearer token.
public record TestUser(Guid Id, string Name, HttpClient Client);

[Collection(IntegrationCollection.Name)]
public abstract class IntegrationTestBase(TestAppFixture fixture) : IAsyncLifetime
{
    protected TestAppFixture Fixture { get; } = fixture;
    protected ApiFactory App => Fixture.App;
    protected RecordingHubContext Hub => Fixture.App.Hub;
    protected FakeBlobService Blob => Fixture.App.Blob;
    protected StubHttpHandler Apns => Fixture.App.Apns;

    /// Mirrors the server's own JSON options (Program.cs) so a test reads exactly the bytes a
    /// client would. Note this is NOT the iOS client's decoder — proving those two agree is the
    /// job of the contract fixtures, not of these tests.
    protected static readonly JsonSerializerOptions Json = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower,
        PropertyNameCaseInsensitive = true,
        Converters = { new JsonStringEnumConverter() }
    };

    public async Task InitializeAsync()
    {
        // Every test starts from an empty database and empty recorders. Nothing carries over,
        // so no test can pass because of what another one left behind.
        await Fixture.Sql.ResetAsync();
        Hub.Clear();
        Apns.Clear();
        App.GitHub.Clear();
        Blob.NextBlobSize = null;
        RateLimiter.Reset();
        DrainPushes();
    }

    public Task DisposeAsync() => Task.CompletedTask;

    /// The send rate limiter is a singleton keyed by user id and survives the database reset, so
    /// without this a later test inherits an earlier one's token count.
    private HubRateLimiter RateLimiter => App.Services.GetRequiredService<HubRateLimiter>();

    /// The push mailbox. The dispatch worker is removed in tests (see ApiFactory), so whatever the
    /// send path enqueued is still sitting here — no polling, no sleeping, no race.
    protected NotificationQueue PushQueue => App.Services.GetRequiredService<NotificationQueue>();

    protected List<NotificationJob> DrainPushes()
    {
        var jobs = new List<NotificationJob>();
        while (PushQueue.Reader.TryRead(out var job)) jobs.Add(job);
        return jobs;
    }

    // ---- seeding -------------------------------------------------------------------------

    protected async Task<Club> CreateClubAsync(string name = "Old Man's Book Club")
    {
        await using var db = App.NewDbContext();
        var club = new Club { Name = name };
        db.Clubs.Add(club);
        await db.SaveChangesAsync();
        return club;
    }

    protected async Task<TestUser> CreateUserAsync(
        string name = "Member",
        Guid? clubId = null,
        bool approved = true,
        bool isAdmin = false,
        bool isClubAdmin = false)
    {
        await using var db = App.NewDbContext();
        var user = new User
        {
            AppleSubject = $"test_{Guid.NewGuid():N}",
            DisplayName = name,
            IsApproved = approved,
            IsAdmin = isAdmin
        };
        db.Users.Add(user);
        if (clubId is { } cid)
            db.Memberships.Add(new Membership { UserId = user.Id, ClubId = cid, IsClubAdmin = isClubAdmin });
        await db.SaveChangesAsync();
        return new TestUser(user.Id, name, ClientFor(user.Id));
    }

    protected async Task<Book> CreateBookAsync(Guid clubId, string title, string status = "current",
        int displayOrder = 0, DateTime? addedAt = null, string? seriesName = null, int? seriesOrder = null)
    {
        await using var db = App.NewDbContext();
        var book = new Book
        {
            ClubId = clubId,
            Title = title,
            Author = "Test Author",
            Status = status,
            DisplayOrder = displayOrder,
            AddedAt = addedAt ?? DateTime.UtcNow,
            SeriesName = seriesName,
            SeriesOrder = seriesOrder
        };
        db.Books.Add(book);
        await db.SaveChangesAsync();
        return book;
    }

    /// Writes a message straight to the database, bypassing the send pipeline. For arranging the
    /// state a test is actually about (an unread message from someone else, say) — never for
    /// testing the send path itself, which must go through the real endpoint.
    protected async Task<Message> InsertMessageAsync(Guid bookId, Guid clubId, Guid senderId,
        MessageType type = MessageType.Text, string? body = "hello", DateTime? sentAt = null,
        DateTime? deletedAt = null, Guid? clientId = null, string? mediaUrl = null)
    {
        await using var db = App.NewDbContext();
        var message = new Message
        {
            BookId = bookId,
            ClubId = clubId,
            SenderId = senderId,
            Type = type,
            Body = type == MessageType.Text ? body : null,
            MediaUrl = mediaUrl ?? (type == MessageType.Text ? null : $"https://{FakeBlobService.Host}/club-media/{clubId}/{Guid.NewGuid()}.m4a"),
            DurationSeconds = type == MessageType.Voice ? 5 : null,
            SentAt = sentAt ?? DateTime.UtcNow,
            DeletedAt = deletedAt,
            ClientId = clientId
        };
        db.Messages.Add(message);
        await db.SaveChangesAsync();
        return message;
    }

    protected async Task RegisterDeviceAsync(Guid userId, string token)
    {
        await using var db = App.NewDbContext();
        db.UserDevices.Add(new UserDevice { UserId = userId, DeviceToken = token });
        await db.SaveChangesAsync();
    }

    // ---- auth ----------------------------------------------------------------------------

    /// Mints a token directly rather than calling /auth/dev-login. That endpoint is wrapped in
    /// `#if !DEBUG return NotFound()`, so it disappears from a Release build — tests that depended
    /// on it would pass locally and 404 in a Release CI job.
    protected HttpClient ClientFor(Guid userId)
    {
        var client = App.CreateClient();
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", TokenFor(userId));
        return client;
    }

    protected static string TokenFor(Guid userId, TimeSpan? lifetime = null)
    {
        var key = new SymmetricSecurityKey(Encoding.UTF8.GetBytes(ApiFactory.JwtSecret));
        var token = new JwtSecurityToken(
            issuer: ApiFactory.JwtIssuer,
            audience: ApiFactory.JwtAudience,
            claims: [new Claim(JwtRegisteredClaimNames.Sub, userId.ToString()),
                     new Claim(JwtRegisteredClaimNames.Jti, Guid.NewGuid().ToString())],
            expires: DateTime.UtcNow.Add(lifetime ?? TimeSpan.FromHours(1)),
            signingCredentials: new SigningCredentials(key, SecurityAlgorithms.HmacSha256));
        return new JwtSecurityTokenHandler().WriteToken(token);
    }

    // ---- assertions helpers ----------------------------------------------------------------

    protected static async Task<T> ReadAsync<T>(HttpResponseMessage response)
    {
        var body = await response.Content.ReadAsStringAsync();
        Assert.True(response.IsSuccessStatusCode, $"{(int)response.StatusCode} {response.StatusCode}: {body}");
        return JsonSerializer.Deserialize<T>(body, Json)
               ?? throw new InvalidOperationException($"Response did not deserialize to {typeof(T).Name}: {body}");
    }

    protected static StringContent JsonBody(object value) =>
        new(JsonSerializer.Serialize(value, Json), Encoding.UTF8, "application/json");
}
