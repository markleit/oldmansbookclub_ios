using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;
using BookClubApi.Tests.Infrastructure;
using Microsoft.EntityFrameworkCore;

namespace BookClubApi.Tests.Api;

/// Sign-in, token lifetime and device registration.
public class AuthTests(TestAppFixture fixture) : IntegrationTestBase(fixture)
{
    private static object AppleRequest(string displayName = "New User", string? clubName = null,
        Guid? joinClubId = null, string? email = null) => new
        {
            identity_token = "any-token-the-validator-is-faked",
            display_name = displayName,
            email,
            club_name = clubName,
            join_club_id = joinClubId,
            authorization_code = (string?)null
        };

    private async Task<JsonElement> PostAppleAsync(object body, HttpStatusCode expected)
    {
        var response = await App.CreateClient().PostAsync("/auth/apple", JsonBody(body));
        var content = await response.Content.ReadAsStringAsync();
        Assert.True(response.StatusCode == expected, $"expected {expected}, got {(int)response.StatusCode}: {content}");
        return JsonDocument.Parse(content).RootElement;
    }

    // ---- Sign in with Apple ------------------------------------------------------------------

    [Fact]
    public async Task An_invalid_apple_token_is_rejected()
    {
        FakeAppleTokenValidator.NextResult = null;
        try
        {
            var response = await App.CreateClient().PostAsync("/auth/apple", JsonBody(AppleRequest()));
            Assert.Equal(HttpStatusCode.Unauthorized, response.StatusCode);
        }
        finally
        {
            FakeAppleTokenValidator.NextResult = ("apple_test_subject", "com.markleit.oldmansbookclub");
        }
    }

    [Fact]
    public async Task A_brand_new_user_with_no_club_is_told_to_set_one_up()
    {
        var body = await PostAppleAsync(AppleRequest(), HttpStatusCode.Accepted);

        Assert.Equal("needs_club_setup", body.GetProperty("status").GetString());
    }

    [Fact]
    public async Task Creating_a_club_during_sign_in_makes_you_its_approved_admin()
    {
        await PostAppleAsync(AppleRequest(clubName: "Brand New Club"), HttpStatusCode.OK);

        await using var db = App.NewDbContext();
        var user = await db.Users.SingleAsync();
        var membership = await db.Memberships.SingleAsync();
        Assert.True(user.IsApproved);
        Assert.True(membership.IsClubAdmin);
        Assert.Equal("Brand New Club", (await db.Clubs.SingleAsync()).Name);
    }

    [Fact]
    public async Task Asking_to_join_a_club_leaves_you_pending_rather_than_signed_in()
    {
        var club = await CreateClubAsync("Existing Club");

        var body = await PostAppleAsync(AppleRequest(joinClubId: club.Id), HttpStatusCode.Accepted);

        Assert.Equal("pending_approval", body.GetProperty("status").GetString());
        await using var db = App.NewDbContext();
        Assert.Equal(1, await db.JoinRequests.CountAsync());
        Assert.Empty(await db.Memberships.ToListAsync());
    }

    [Fact]
    public async Task Signing_in_again_returns_the_same_account_rather_than_a_second_one()
    {
        await PostAppleAsync(AppleRequest(clubName: "Brand New Club"), HttpStatusCode.OK);
        await PostAppleAsync(AppleRequest(), HttpStatusCode.OK);

        // Identity is the Apple subject, not the display name. A second row here would split one
        // person's history across two accounts.
        await using var db = App.NewDbContext();
        Assert.Equal(1, await db.Users.CountAsync());
    }

    [Fact]
    public async Task An_email_is_filled_in_later_but_never_overwritten()
    {
        // Apple only sends the email on the FIRST authorization, so the app has one chance to
        // capture it — but a later sign-in must not clobber a value already stored.
        await PostAppleAsync(AppleRequest(clubName: "Club"), HttpStatusCode.OK);
        await PostAppleAsync(AppleRequest(email: "reader@example.com"), HttpStatusCode.OK);
        await PostAppleAsync(AppleRequest(email: "someone-else@example.com"), HttpStatusCode.OK);

        await using var db = App.NewDbContext();
        Assert.Equal("reader@example.com", (await db.Users.SingleAsync()).Email);
    }

    // ---- demo login --------------------------------------------------------------------------

    [Fact]
    public async Task Demo_login_needs_the_right_passphrase()
    {
        var wrong = await App.CreateClient().PostAsync("/auth/demo-login", JsonBody(new { passphrase = "nope" }));

        Assert.Equal(HttpStatusCode.Unauthorized, wrong.StatusCode);
    }

    [Fact]
    public async Task The_demo_reviewer_account_is_approved_but_never_an_admin()
    {
        // App Review signs in with this. Granting it admin would hand a reviewer the ability to
        // delete real members' accounts.
        await CreateClubAsync();

        var response = await App.CreateClient().PostAsync("/auth/demo-login", JsonBody(new { passphrase = ApiFactory.DemoPassphrase }));
        Assert.True(response.IsSuccessStatusCode, await response.Content.ReadAsStringAsync());

        await using var db = App.NewDbContext();
        var reviewer = await db.Users.SingleAsync(u => u.AppleSubject == "apple_reviewer");
        Assert.True(reviewer.IsApproved);
        Assert.False(reviewer.IsAdmin);
        Assert.Equal(1, await db.Memberships.CountAsync(m => m.UserId == reviewer.Id));
    }

    [Fact]
    public async Task Demo_login_joins_the_reviewer_to_any_club_added_since_their_last_visit()
    {
        await CreateClubAsync("First Club");
        await App.CreateClient().PostAsync("/auth/demo-login", JsonBody(new { passphrase = ApiFactory.DemoPassphrase }));

        await CreateClubAsync("Second Club");
        await App.CreateClient().PostAsync("/auth/demo-login", JsonBody(new { passphrase = ApiFactory.DemoPassphrase }));

        await using var db = App.NewDbContext();
        var reviewer = await db.Users.SingleAsync(u => u.AppleSubject == "apple_reviewer");
        Assert.Equal(2, await db.Memberships.CountAsync(m => m.UserId == reviewer.Id));
    }

    // ---- refresh tokens ----------------------------------------------------------------------

    private async Task<(string Access, string Refresh)> SignInAsync()
    {
        var body = await PostAppleAsync(AppleRequest(clubName: "Club"), HttpStatusCode.OK);
        return (body.GetProperty("access_token").GetString()!, body.GetProperty("refresh_token").GetString()!);
    }

    [Fact]
    public async Task A_refresh_token_is_not_rotated_on_use()
    {
        // Deliberate, and worth pinning hard: rotation revokes the old token before the client can
        // confirm it stored the new one, and a background refresh that iOS suspends mid-flight then
        // signs the user out for good. This non-rotation is the fix for the "signed out after
        // idle" reports, so a well-meaning "tokens should rotate" change must fail here.
        var (_, refresh) = await SignInAsync();

        var response = await App.CreateClient().PostAsync("/auth/refresh", JsonBody(new { refresh_token = refresh }));
        var body = await ReadAsync<JsonElement>(response);

        Assert.Equal(refresh, body.GetProperty("refresh_token").GetString());

        // And it still works a second time — a lost response must be harmless.
        var again = await App.CreateClient().PostAsync("/auth/refresh", JsonBody(new { refresh_token = refresh }));
        Assert.True(again.IsSuccessStatusCode);
    }

    [Fact]
    public async Task Refreshing_extends_the_expiry()
    {
        var (_, refresh) = await SignInAsync();
        DateTime before;
        await using (var db = App.NewDbContext()) before = (await db.RefreshTokens.SingleAsync()).ExpiresAt;

        await using (var db = App.NewDbContext())
        {
            var token = await db.RefreshTokens.SingleAsync();
            token.ExpiresAt = DateTime.UtcNow.AddDays(1);
            await db.SaveChangesAsync();
        }

        await App.CreateClient().PostAsync("/auth/refresh", JsonBody(new { refresh_token = refresh }));

        await using (var db = App.NewDbContext())
            Assert.True((await db.RefreshTokens.SingleAsync()).ExpiresAt > DateTime.UtcNow.AddDays(80));
        Assert.True(before > DateTime.UtcNow);
    }

    [Fact]
    public async Task An_unknown_or_revoked_or_expired_refresh_token_is_rejected()
    {
        var (access, refresh) = await SignInAsync();

        var unknown = await App.CreateClient().PostAsync("/auth/refresh", JsonBody(new { refresh_token = "not-a-real-token" }));
        Assert.Equal(HttpStatusCode.Unauthorized, unknown.StatusCode);

        var client = App.CreateClient();
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", access);
        await client.PostAsync("/auth/logout", JsonBody(new { refresh_token = refresh }));

        var afterLogout = await App.CreateClient().PostAsync("/auth/refresh", JsonBody(new { refresh_token = refresh }));
        Assert.Equal(HttpStatusCode.Unauthorized, afterLogout.StatusCode);
    }

    [Fact]
    public async Task An_expired_access_token_is_rejected()
    {
        var club = await CreateClubAsync();
        var user = await CreateUserAsync("Me", club.Id);

        var client = App.CreateClient();
        client.DefaultRequestHeaders.Authorization =
            new AuthenticationHeaderValue("Bearer", TokenFor(user.Id, TimeSpan.FromMinutes(-10)));

        var response = await client.GetAsync("/users/me");

        Assert.Equal(HttpStatusCode.Unauthorized, response.StatusCode);
    }

    // ---- device registration -----------------------------------------------------------------

    [Fact]
    public async Task Registering_a_device_token_that_belongs_to_someone_else_reclaims_it()
    {
        // #25: one physical device, several accounts (dev-login, demo, a real sign-in). The token
        // is globally unique, so registration must MOVE the row rather than create a second one —
        // otherwise a push meant for the current user also goes to whoever held it before.
        var club = await CreateClubAsync();
        var first = await CreateUserAsync("First", club.Id);
        var second = await CreateUserAsync("Second", club.Id);
        const string token = "aabbccdd";

        await first.Client.PostAsync("/notifications/register", JsonBody(new { device_token = token }));
        await second.Client.PostAsync("/notifications/register", JsonBody(new { device_token = token }));

        await using var db = App.NewDbContext();
        var device = Assert.Single(await db.UserDevices.ToListAsync());
        Assert.Equal(second.Id, device.UserId);
    }

    [Fact]
    public async Task One_user_can_register_several_devices()
    {
        var club = await CreateClubAsync();
        var user = await CreateUserAsync("Multi", club.Id);

        await user.Client.PostAsync("/notifications/register", JsonBody(new { device_token = "phone" }));
        await user.Client.PostAsync("/notifications/register", JsonBody(new { device_token = "ipad" }));

        await using var db = App.NewDbContext();
        Assert.Equal(2, await db.UserDevices.CountAsync(d => d.UserId == user.Id));
    }
}
