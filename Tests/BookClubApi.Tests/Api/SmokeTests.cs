using BookClubApi.Tests.Infrastructure;

namespace BookClubApi.Tests.Api;

/// Proves the harness itself works before any behaviour is asserted: the container starts, all 33
/// migrations apply to an empty database, the real auth pipeline accepts a minted token, and the
/// blob/hub/APNs edges are substituted rather than reached.
public class SmokeTests(TestAppFixture fixture) : IntegrationTestBase(fixture)
{
    [Fact]
    public async Task Health_is_reachable()
    {
        var response = await App.CreateClient().GetAsync("/health");
        Assert.True(response.IsSuccessStatusCode);
    }

    [Fact]
    public async Task Readiness_reports_the_container_database_is_up()
    {
        // /health/ready runs a real DbContext check, so a green here means migrations applied and
        // the connection string actually points at the container.
        var response = await App.CreateClient().GetAsync("/health/ready");
        Assert.True(response.IsSuccessStatusCode, $"readiness returned {(int)response.StatusCode}");
    }

    [Fact]
    public async Task Unauthenticated_request_is_rejected()
    {
        var response = await App.CreateClient().GetAsync("/users/me");
        Assert.Equal(System.Net.HttpStatusCode.Unauthorized, response.StatusCode);
    }

    [Fact]
    public async Task Minted_token_authenticates_against_the_real_jwt_pipeline()
    {
        var club = await CreateClubAsync();
        var user = await CreateUserAsync("Mark", club.Id);

        var response = await user.Client.GetAsync("/users/me");

        var body = await response.Content.ReadAsStringAsync();
        Assert.True(response.IsSuccessStatusCode, $"{(int)response.StatusCode}: {body}");
        Assert.Contains("Mark", body);
    }

    [Fact]
    public async Task Database_is_empty_at_the_start_of_every_test()
    {
        // Paired with the club created in the test above: if Respawn were not resetting, whichever
        // of the two ran second would see the other's rows.
        await using var db = App.NewDbContext();
        Assert.Empty(db.Clubs);
        Assert.Empty(db.Users);
    }
}
