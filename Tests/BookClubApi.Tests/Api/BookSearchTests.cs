using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using BookClubApi.Tests.Infrastructure;
using Microsoft.EntityFrameworkCore;

namespace BookClubApi.Tests.Api;

/// Add Book search and the first-open details backfill, both backed by Google Books (stubbed).
/// Since Oct 2026 Google returns nothing for field-qualified queries ("intitle:Dune") while the
/// plain title still works — every search in the app came back empty for weeks and looked like an
/// outage. These pin the fallback, and that "Google is down" is no longer reported as "no matches".
public class BookSearchTests(TestAppFixture fixture) : IntegrationTestBase(fixture)
{
    private const string DuneVolumes = """
        {"kind":"books#volumes","totalItems":1,"items":[{"volumeInfo":{
          "title":"Dune","authors":["Frank Herbert"],"publishedDate":"1965-08-01","pageCount":412,
          "description":"A desert planet.",
          "imageLinks":{"thumbnail":"http://books.google.com/books/content?id=dune1&img=1&zoom=1"}}}]}
        """;

    private static HttpResponseMessage Json200(string body) =>
        new(HttpStatusCode.OK) { Content = new StringContent(body) };

    private static string QueryOf(HttpRequestMessage request) =>
        System.Web.HttpUtility.ParseQueryString(request.RequestUri!.Query)["q"] ?? "";

    /// Google as it behaves now: field-qualified queries match nothing, plain ones work.
    private void GoogleIgnoresFieldQueries() =>
        App.GoogleBooks.Responder = (request, _) => QueryOf(request).StartsWith("intitle:")
            ? StubHttpHandler.NoGoogleBooksMatches(request, "")
            : Json200(DuneVolumes);

    private string[] QueriesSent() => [.. App.GoogleBooks.Requests.Select(r => QueryOf(r.Request))];

    [Fact]
    public async Task Search_falls_back_to_the_plain_title_when_the_title_query_finds_nothing()
    {
        var club = await CreateClubAsync();
        var user = await CreateUserAsync("Member", club.Id);
        GoogleIgnoresFieldQueries();

        var response = await user.Client.GetAsync("/books/search?q=Dune");

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        var results = JsonDocument.Parse(await response.Content.ReadAsStringAsync()).RootElement;
        Assert.Equal(1, results.GetArrayLength());
        Assert.Equal("Dune", results[0].GetProperty("title").GetString());
        Assert.Equal("Frank Herbert", results[0].GetProperty("author").GetString());
        Assert.Equal(["intitle:Dune", "Dune"], QueriesSent());
    }

    [Fact]
    public async Task Search_uses_the_title_query_alone_when_it_matches()
    {
        var club = await CreateClubAsync();
        var user = await CreateUserAsync("Member", club.Id);
        App.GoogleBooks.Responder = (_, _) => Json200(DuneVolumes);

        var response = await user.Client.GetAsync("/books/search?q=Dune");

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        Assert.Equal(1, JsonDocument.Parse(await response.Content.ReadAsStringAsync()).RootElement.GetArrayLength());
        Assert.Equal(["intitle:Dune"], QueriesSent());
    }

    [Fact]
    public async Task Search_with_no_matches_is_an_empty_list()
    {
        var club = await CreateClubAsync();
        var user = await CreateUserAsync("Member", club.Id);

        var response = await user.Client.GetAsync("/books/search?q=Xyzzy");

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        Assert.Equal(0, JsonDocument.Parse(await response.Content.ReadAsStringAsync()).RootElement.GetArrayLength());
    }

    [Theory]
    [InlineData(HttpStatusCode.ServiceUnavailable)]
    [InlineData(HttpStatusCode.TooManyRequests)]
    public async Task Search_reports_Google_being_unavailable_as_503_not_as_no_matches(HttpStatusCode googleStatus)
    {
        var club = await CreateClubAsync();
        var user = await CreateUserAsync("Member", club.Id);
        App.GoogleBooks.Responder = (_, _) => new HttpResponseMessage(googleStatus) { Content = new StringContent("{}") };

        var response = await user.Client.GetAsync("/books/search?q=Dune");

        Assert.Equal(HttpStatusCode.ServiceUnavailable, response.StatusCode);
        Assert.Equal(["intitle:Dune"], QueriesSent());   // no pointless second query
    }

    [Fact]
    public async Task Search_reports_an_unreadable_Google_answer_as_503()
    {
        var club = await CreateClubAsync();
        var user = await CreateUserAsync("Member", club.Id);
        App.GoogleBooks.Responder = (_, _) => Json200("<html>not json</html>");

        var response = await user.Client.GetAsync("/books/search?q=Dune");

        Assert.Equal(HttpStatusCode.ServiceUnavailable, response.StatusCode);
    }

    [Fact]
    public async Task First_open_fills_details_through_the_plain_title_fallback()
    {
        var club = await CreateClubAsync();
        var user = await CreateUserAsync("Member", club.Id);
        var book = await CreateBookAsync(club.Id, "Dune");
        GoogleIgnoresFieldQueries();

        var response = await user.Client.GetAsync($"/books/{book.Id}");

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        await using var db = App.NewDbContext();
        var stored = await db.Books.SingleAsync(b => b.Id == book.Id);
        Assert.Equal("A desert planet.", stored.Description);
        Assert.Equal(1965, stored.PublishedYear);
        Assert.Equal(412, stored.PageCount);
        Assert.NotNull(stored.MetadataFetchedAt);
    }

    [Fact]
    public async Task First_open_while_Google_is_down_tries_again_on_the_next_open()
    {
        var club = await CreateClubAsync();
        var user = await CreateUserAsync("Member", club.Id);
        var book = await CreateBookAsync(club.Id, "Dune");
        App.GoogleBooks.Responder = (_, _) => new HttpResponseMessage(HttpStatusCode.ServiceUnavailable) { Content = new StringContent("{}") };

        Assert.Equal(HttpStatusCode.OK, (await user.Client.GetAsync($"/books/{book.Id}")).StatusCode);
        await using (var db = App.NewDbContext())
            Assert.Null((await db.Books.SingleAsync(b => b.Id == book.Id)).MetadataFetchedAt);

        App.GoogleBooks.Responder = (_, _) => Json200(DuneVolumes);
        await user.Client.GetAsync($"/books/{book.Id}");

        await using (var db = App.NewDbContext())
        {
            var stored = await db.Books.SingleAsync(b => b.Id == book.Id);
            Assert.Equal(412, stored.PageCount);
            Assert.NotNull(stored.MetadataFetchedAt);
        }
    }

    [Fact]
    public async Task First_open_with_no_match_is_not_retried()
    {
        var club = await CreateClubAsync();
        var user = await CreateUserAsync("Member", club.Id);
        var book = await CreateBookAsync(club.Id, "Xyzzy");

        await user.Client.GetAsync($"/books/{book.Id}");
        await user.Client.GetAsync($"/books/{book.Id}");

        Assert.Equal(["intitle:Xyzzy", "Xyzzy"], QueriesSent());   // one attempt, both queries, then done
    }
}
