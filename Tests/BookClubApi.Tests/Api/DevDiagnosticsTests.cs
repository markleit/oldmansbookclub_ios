using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using BookClubApi.Tests.Infrastructure;
using Microsoft.AspNetCore.Hosting;
using Microsoft.Extensions.Hosting;

namespace BookClubApi.Tests.Api;

/// #204 (T5) — the dev-only "what did the server actually receive" listing used to verify device
/// test runs. It exposes every book's messages, so both gates matter: Development only, and the
/// seed key.
public class DevDiagnosticsTests(TestAppFixture fixture) : IntegrationTestBase(fixture)
{
    [Fact]
    public async Task Recent_messages_list_client_ids_for_a_caller_with_the_seed_key()
    {
        var club = await CreateClubAsync();
        var book = await CreateBookAsync(club.Id, "The Road");
        var sender = await CreateUserAsync("Mark", club.Id);
        var clientId = Guid.NewGuid();
        await InsertMessageAsync(book.Id, club.Id, sender.Id, clientId: clientId);

        var request = new HttpRequestMessage(HttpMethod.Get, $"/admin/dev/recent-messages?book_id={book.Id}");
        request.Headers.Add("X-Seed-Key", ApiFactory.SeedingKey);
        var rows = await ReadAsync<JsonElement>(await App.CreateClient().SendAsync(request));

        var row = Assert.Single(rows.EnumerateArray());
        Assert.Equal(clientId, row.GetProperty("client_id").GetGuid());
        Assert.Equal("Mark", row.GetProperty("sender_name").GetString());
    }

    [Fact]
    public async Task Recent_messages_need_the_seed_key()
    {
        var response = await App.CreateClient().GetAsync("/admin/dev/recent-messages");

        Assert.Equal(HttpStatusCode.Unauthorized, response.StatusCode);
    }

    [Fact]
    public async Task Recent_messages_do_not_exist_outside_development()
    {
        await using var production = App.WithWebHostBuilder(b => b.UseEnvironment(Environments.Production));
        var request = new HttpRequestMessage(HttpMethod.Get, "/admin/dev/recent-messages");
        request.Headers.Add("X-Seed-Key", ApiFactory.SeedingKey);

        var response = await production.CreateClient().SendAsync(request);

        Assert.Equal(HttpStatusCode.NotFound, response.StatusCode);
    }
}
