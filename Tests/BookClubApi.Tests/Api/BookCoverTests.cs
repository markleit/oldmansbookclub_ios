using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using BookClubApi.Tests.Infrastructure;
using Microsoft.EntityFrameworkCore;

namespace BookClubApi.Tests.Api;

/// Edit Book → change cover (2.1). The cover is the first thing every member sees in the
/// library, and it is a client-supplied URL, so what's accepted, how it's stored, how it's served,
/// and that nothing later silently replaces it are all worth pinning down.
public class BookCoverTests(TestAppFixture fixture) : IntegrationTestBase(fixture)
{
    private static string OwnUpload(Guid clubId) =>
        $"https://{FakeBlobService.Host}/club-media/{clubId}/{Guid.NewGuid()}.jpg";

    private const string GoogleCover = "https://books.google.com/books/content?id=abc123&printsec=frontcover&img=1&zoom=1";

    private async Task<string?> CoverInLibrary(TestUser user, Guid bookId)
    {
        var body = await (await user.Client.GetAsync("/books")).Content.ReadAsStringAsync();
        return JsonDocument.Parse(body).RootElement.EnumerateArray()
            .First(b => b.GetProperty("id").GetGuid() == bookId)
            .GetProperty("cover_blob_url").GetString();
    }

    [Fact]
    public async Task An_uploaded_cover_is_stored_plain_and_served_with_a_fresh_signature()
    {
        var club = await CreateClubAsync();
        var admin = await CreateUserAsync("Admin", club.Id, isClubAdmin: true);
        var book = await CreateBookAsync(club.Id, "Dune");
        var upload = OwnUpload(club.Id);

        var response = await admin.Client.PatchAsJsonAsync($"/books/{book.Id}",
            new { title = "Dune", author = "Frank Herbert", cover_url = upload + "?sig=fake-write" });
        Assert.True(response.IsSuccessStatusCode, await response.Content.ReadAsStringAsync());

        await using (var db = App.NewDbContext())
            Assert.Equal(upload, (await db.Books.SingleAsync(b => b.Id == book.Id)).CoverBlobUrl);

        // The container is private: what the app gets must carry a read signature.
        Assert.Equal(upload + "?sig=fake-read", await CoverInLibrary(admin, book.Id));
    }

    [Fact]
    public async Task A_google_books_cover_is_accepted_and_served_unchanged()
    {
        var club = await CreateClubAsync();
        var admin = await CreateUserAsync("Admin", club.Id, isClubAdmin: true);
        var book = await CreateBookAsync(club.Id, "Dune");

        var response = await admin.Client.PatchAsJsonAsync($"/books/{book.Id}",
            new { title = "Dune", author = "Frank Herbert", cover_url = GoogleCover });
        Assert.True(response.IsSuccessStatusCode, await response.Content.ReadAsStringAsync());

        Assert.Equal(GoogleCover, await CoverInLibrary(admin, book.Id));
    }

    [Theory]
    [InlineData("other-club")]
    [InlineData("foreign-host")]
    [InlineData("plain-http")]
    public async Task A_cover_from_anywhere_else_is_rejected(string kind)
    {
        var club = await CreateClubAsync();
        var otherClub = await CreateClubAsync("Another Club");
        var admin = await CreateUserAsync("Admin", club.Id, isClubAdmin: true);
        var book = await CreateBookAsync(club.Id, "Dune");
        var url = kind switch
        {
            "other-club" => OwnUpload(otherClub.Id),
            "foreign-host" => "https://example.com/cover.jpg",
            _ => GoogleCover.Replace("https://", "http://"),
        };

        var response = await admin.Client.PatchAsJsonAsync($"/books/{book.Id}",
            new { title = "Dune", author = "Frank Herbert", cover_url = url });

        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
        await using var db = App.NewDbContext();
        Assert.Null((await db.Books.SingleAsync(b => b.Id == book.Id)).CoverBlobUrl);
    }

    [Fact]
    public async Task Leaving_the_cover_out_keeps_it_which_is_what_older_apps_send()
    {
        var club = await CreateClubAsync();
        var admin = await CreateUserAsync("Admin", club.Id, isClubAdmin: true);
        var book = await CreateBookAsync(club.Id, "Dune");
        await admin.Client.PatchAsJsonAsync($"/books/{book.Id}",
            new { title = "Dune", author = "Frank Herbert", cover_url = GoogleCover });

        var response = await admin.Client.PatchAsJsonAsync($"/books/{book.Id}",
            new { title = "Dune (Renamed)", author = "Frank Herbert" });
        Assert.True(response.IsSuccessStatusCode, await response.Content.ReadAsStringAsync());

        Assert.Equal(GoogleCover, await CoverInLibrary(admin, book.Id));
    }

    [Fact]
    public async Task Only_a_club_admin_can_change_the_cover()
    {
        var club = await CreateClubAsync();
        var member = await CreateUserAsync("Member", club.Id);
        var book = await CreateBookAsync(club.Id, "Dune");

        var response = await member.Client.PatchAsJsonAsync($"/books/{book.Id}",
            new { title = "Dune", author = "Frank Herbert", cover_url = OwnUpload(club.Id) });

        Assert.Equal(HttpStatusCode.Forbidden, response.StatusCode);
    }

    [Fact]
    public async Task A_chosen_cover_is_not_replaced_by_the_first_time_details_backfill()
    {
        // GetBook fills a never-fetched book's details from Google Books the first time it's
        // opened — and used to overwrite the cover with the top search match while doing it.
        var club = await CreateClubAsync();
        var admin = await CreateUserAsync("Admin", club.Id, isClubAdmin: true);
        var book = await CreateBookAsync(club.Id, "Dune");
        var upload = OwnUpload(club.Id);

        await admin.Client.PatchAsJsonAsync($"/books/{book.Id}",
            new { title = "Dune", author = "Frank Herbert", cover_url = upload });

        await using (var db = App.NewDbContext())
            Assert.NotNull((await db.Books.SingleAsync(b => b.Id == book.Id)).MetadataFetchedAt);

        var details = await admin.Client.GetAsync($"/books/{book.Id}");
        var cover = JsonDocument.Parse(await details.Content.ReadAsStringAsync()).RootElement
            .GetProperty("cover_blob_url").GetString();
        Assert.Equal(upload + "?sig=fake-read", cover);
    }
}
