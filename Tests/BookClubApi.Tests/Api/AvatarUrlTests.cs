using System.Net;
using System.Net.Http.Json;
using BookClubApi.Tests.Infrastructure;

namespace BookClubApi.Tests.Api;

/// #210: an avatar is accepted only from this server's own storage account — whichever that is
/// (prod's in production, the dev account in Development). It used to be a hardcoded prod host,
/// so every avatar saved against the dev API was rejected.
public class AvatarUrlTests(TestAppFixture fixture) : IntegrationTestBase(fixture)
{
    [Fact]
    public async Task An_avatar_on_this_servers_storage_is_saved()
    {
        var club = await CreateClubAsync();
        var user = await CreateUserAsync("Walt", club.Id);
        var url = $"https://{FakeBlobService.Host}/avatars/{Guid.NewGuid()}.jpg";

        var response = await user.Client.PatchAsJsonAsync("/users/me", new { avatar_url = url }, Json);

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
    }

    [Theory]
    [InlineData("https://oldmansbookclubstore.blob.core.windows.net/avatars/x.jpg")]   // another account (prod's, here)
    [InlineData("https://example.com/avatar.jpg")]
    public async Task An_avatar_from_anywhere_else_is_refused(string url)
    {
        var club = await CreateClubAsync();
        var user = await CreateUserAsync("Walt", club.Id);

        var response = await user.Client.PatchAsJsonAsync("/users/me", new { avatar_url = url }, Json);

        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
    }
}
