using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using BookClubApi.Tests.Infrastructure;
using Microsoft.EntityFrameworkCore;

namespace BookClubApi.Tests.Api;

/// The details page (description / year / pages) must describe the book the club picked, not
/// whatever Google ranks first for its title. "The Treasure Hunters Club" was added with the right
/// cover; the first open replaced that cover and filled in another book's details, and changing
/// the cover back in Edit Book left the wrong details in place.
public class BookDetailsMatchTests(TestAppFixture fixture) : IntegrationTestBase(fixture)
{
    private const string Title = "The Treasure Hunters Club";
    private const string Author = "Tom Hardy";
    private const string PickedCover = "https://books.google.com/books/content?id=picked1&printsec=frontcover&img=1&zoom=1";
    private const string OtherCover = "https://books.google.com/books/content?id=other22&printsec=frontcover&img=1&zoom=1";

    private static string Volume(string id, string title, string author, string description, int year, int pages) =>
        JsonSerializer.Serialize(new
        {
            id,
            volumeInfo = new
            {
                title, authors = new[] { author }, publishedDate = year.ToString(), pageCount = pages, description,
                imageLinks = new { thumbnail = $"http://books.google.com/books/content?id={id}&img=1&zoom=1" },
            },
        });



    // The right book, and a different one with a similar title that Google ranks above it.
    private static readonly string Picked = Volume("picked1", Title, Author, "The right book.", 2024, 320);
    private static readonly string Impostor = Volume("impostor", "Treasure Hunters", "James Patterson", "Another book.", 2013, 450);

    private static HttpResponseMessage Json200(string body) =>
        new(HttpStatusCode.OK) { Content = new StringContent(body) };

    private static string Search(params string[] volumes) =>
        $$"""{"kind":"books#volumes","totalItems":{{volumes.Length}},"items":[{{string.Join(",", volumes)}}]}""";

    /// Google: volumes/{id} answers from `byId` (404 when missing); a search answers `search`.
    private void Google(Dictionary<string, string> byId, string search) =>
        App.GoogleBooks.Responder = (request, _) =>
        {
            var path = request.RequestUri!.AbsolutePath;
            var marker = "/volumes/";
            var at = path.IndexOf(marker, StringComparison.Ordinal);
            if (at < 0) return Json200(search);
            return byId.TryGetValue(path[(at + marker.Length)..], out var v)
                ? Json200(v)
                : new HttpResponseMessage(HttpStatusCode.NotFound) { Content = new StringContent("{}") };
        };

    private string[] VolumeIdsFetched() =>
        [.. App.GoogleBooks.Requests.Select(r => r.Request.RequestUri!.AbsolutePath)
            .Where(p => p.Contains("/volumes/")).Select(p => p[(p.LastIndexOf('/') + 1)..])];

    private async Task<Models_Book> StoredAsync(Guid bookId)
    {
        await using var db = App.NewDbContext();
        var b = await db.Books.SingleAsync(x => x.Id == bookId);
        return new(b.Description, b.PublishedYear, b.PageCount, b.CoverBlobUrl, b.MetadataFetchedAt);
    }

    private record Models_Book(string? Description, int? Year, int? Pages, string? Cover, DateTime? FetchedAt);

    [Fact]
    public async Task A_book_added_from_search_gets_the_details_of_that_exact_volume_and_keeps_its_cover()
    {
        var club = await CreateClubAsync();
        var user = await CreateUserAsync("Member", club.Id);
        var book = await CreateBookAsync(club.Id, Title, author: Author, coverUrl: PickedCover);
        Google(new() { ["picked1"] = Picked }, search: Search(Impostor, Picked));

        var response = await user.Client.GetAsync($"/books/{book.Id}");

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        var stored = await StoredAsync(book.Id);
        Assert.Equal("The right book.", stored.Description);
        Assert.Equal(2024, stored.Year);
        Assert.Equal(320, stored.Pages);
        Assert.Equal(PickedCover, stored.Cover);
        Assert.Equal(["picked1"], VolumeIdsFetched());
    }

    [Fact]
    public async Task Without_a_google_cover_only_a_result_with_the_same_title_and_author_is_used()
    {
        var club = await CreateClubAsync();
        var user = await CreateUserAsync("Member", club.Id);
        var book = await CreateBookAsync(club.Id, Title, author: Author);
        Google([], search: Search(Impostor, Picked));

        await user.Client.GetAsync($"/books/{book.Id}");

        var stored = await StoredAsync(book.Id);
        Assert.Equal("The right book.", stored.Description);
        // A book with no cover may take the matching volume's.
        Assert.Contains("id=picked1", stored.Cover);
    }

    [Fact]
    public async Task When_no_result_is_the_same_book_the_details_stay_blank_rather_than_wrong()
    {
        var club = await CreateClubAsync();
        var user = await CreateUserAsync("Member", club.Id);
        var photo = $"https://{FakeBlobService.Host}/club-media/{club.Id}/{Guid.NewGuid()}.jpg";
        var book = await CreateBookAsync(club.Id, Title, author: Author, coverUrl: photo);
        Google([], search: Search(Impostor));

        await user.Client.GetAsync($"/books/{book.Id}");

        var stored = await StoredAsync(book.Id);
        Assert.Null(stored.Description);
        Assert.Null(stored.Pages);
        Assert.Equal(photo, stored.Cover);
        Assert.NotNull(stored.FetchedAt);   // a real "no match" — not retried on every open
    }

    [Fact]
    public async Task A_same_titled_book_by_another_author_is_not_a_match()
    {
        var club = await CreateClubAsync();
        var user = await CreateUserAsync("Member", club.Id);
        var book = await CreateBookAsync(club.Id, Title, author: Author);
        Google([], search: Search(Volume("x9", Title, "Someone Else", "Same title, other book.", 1999, 100)));

        await user.Client.GetAsync($"/books/{book.Id}");

        Assert.Null((await StoredAsync(book.Id)).Description);
    }

    [Fact]
    public async Task A_cover_volume_google_no_longer_has_falls_back_to_a_matching_search_result()
    {
        var club = await CreateClubAsync();
        var user = await CreateUserAsync("Member", club.Id);
        var book = await CreateBookAsync(club.Id, Title, author: Author, coverUrl: OtherCover);
        Google([], search: Search(Impostor, Picked));

        await user.Client.GetAsync($"/books/{book.Id}");

        var stored = await StoredAsync(book.Id);
        Assert.Equal("The right book.", stored.Description);
        Assert.Equal(OtherCover, stored.Cover);
    }

    [Fact]
    public async Task Google_down_during_the_volume_fetch_retries_on_the_next_open()
    {
        var club = await CreateClubAsync();
        var user = await CreateUserAsync("Member", club.Id);
        var book = await CreateBookAsync(club.Id, Title, author: Author, coverUrl: PickedCover);
        App.GoogleBooks.Responder = (_, _) => new HttpResponseMessage(HttpStatusCode.ServiceUnavailable) { Content = new StringContent("{}") };

        Assert.Equal(HttpStatusCode.OK, (await user.Client.GetAsync($"/books/{book.Id}")).StatusCode);
        Assert.Null((await StoredAsync(book.Id)).FetchedAt);

        Google(new() { ["picked1"] = Picked }, search: Search());
        await user.Client.GetAsync($"/books/{book.Id}");
        Assert.Equal("The right book.", (await StoredAsync(book.Id)).Description);
    }

    [Fact]
    public async Task Changing_the_cover_in_edit_book_replaces_the_old_details_with_the_new_volumes()
    {
        // The reported case: the first open filled in another book's details; the admin then
        // picked the right cover in Edit Book. The wrong details must not survive that.
        var club = await CreateClubAsync();
        var admin = await CreateUserAsync("Admin", club.Id, isClubAdmin: true);
        var book = await CreateBookAsync(club.Id, Title, author: Author, coverUrl: OtherCover);
        Google(new() { ["other22"] = Impostor, ["picked1"] = Picked }, search: Search());
        await admin.Client.GetAsync($"/books/{book.Id}");
        Assert.Equal("Another book.", (await StoredAsync(book.Id)).Description);

        var response = await admin.Client.PatchAsJsonAsync($"/books/{book.Id}",
            new { title = Title, author = Author, cover_url = PickedCover });
        Assert.True(response.IsSuccessStatusCode, await response.Content.ReadAsStringAsync());

        var body = JsonDocument.Parse(await response.Content.ReadAsStringAsync()).RootElement;
        Assert.Equal("The right book.", body.GetProperty("description").GetString());
        var stored = await StoredAsync(book.Id);
        Assert.Equal(320, stored.Pages);
        Assert.Equal(PickedCover, stored.Cover);
    }

    [Fact]
    public async Task Editing_only_the_series_keeps_the_details_and_does_not_ask_google()
    {
        var club = await CreateClubAsync();
        var admin = await CreateUserAsync("Admin", club.Id, isClubAdmin: true);
        var book = await CreateBookAsync(club.Id, Title, author: Author, coverUrl: PickedCover);
        Google(new() { ["picked1"] = Picked }, search: Search());
        await admin.Client.GetAsync($"/books/{book.Id}");
        App.GoogleBooks.Clear();

        var response = await admin.Client.PatchAsJsonAsync($"/books/{book.Id}",
            new { title = Title, author = Author, series_name = "Treasure" });
        Assert.True(response.IsSuccessStatusCode, await response.Content.ReadAsStringAsync());

        Assert.Equal("The right book.", (await StoredAsync(book.Id)).Description);
        Assert.Empty(App.GoogleBooks.Requests);
    }

    [Fact]
    public async Task Renaming_the_book_refetches_its_details()
    {
        var club = await CreateClubAsync();
        var admin = await CreateUserAsync("Admin", club.Id, isClubAdmin: true);
        var photo = $"https://{FakeBlobService.Host}/club-media/{club.Id}/{Guid.NewGuid()}.jpg";
        var book = await CreateBookAsync(club.Id, "Treasure Hunters", author: "James Patterson", coverUrl: photo);
        Google([], search: Search(Impostor, Picked));
        await admin.Client.GetAsync($"/books/{book.Id}");
        Assert.Equal("Another book.", (await StoredAsync(book.Id)).Description);

        await admin.Client.PatchAsJsonAsync($"/books/{book.Id}", new { title = Title, author = Author });

        var stored = await StoredAsync(book.Id);
        Assert.Equal("The right book.", stored.Description);
        Assert.Equal(photo, stored.Cover);
    }
}
