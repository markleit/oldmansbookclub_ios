using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using BookClubApi.Models;
using BookClubApi.Tests.Infrastructure;
using Microsoft.EntityFrameworkCore;

namespace BookClubApi.Tests.Api;

/// The books list and its ordering — the first screen every user sees, and the part of the API
/// that has churned most recently (#137, #138, #144), which is exactly the combination that earns
/// regression coverage.
public class LibraryTests(TestAppFixture fixture) : IntegrationTestBase(fixture)
{
    private async Task<List<string>> TitlesInOrder(TestUser user)
    {
        var response = await user.Client.GetAsync("/books");
        var body = await response.Content.ReadAsStringAsync();
        Assert.True(response.IsSuccessStatusCode, body);
        return [.. JsonDocument.Parse(body).RootElement.EnumerateArray()
            .Select(b => b.GetProperty("title").GetString()!)];
    }

    [Fact]
    public async Task Books_sort_by_status_then_display_order_then_newest_added()
    {
        var club = await CreateClubAsync();
        var me = await CreateUserAsync("Me", club.Id);
        var baseTime = new DateTime(2026, 1, 1, 0, 0, 0, DateTimeKind.Utc);

        // Deliberately created out of order, so passing can't be an accident of insertion order.
        await CreateBookAsync(club.Id, "Past", "past", displayOrder: 0);
        await CreateBookAsync(club.Id, "Future B", "future", displayOrder: 1);
        await CreateBookAsync(club.Id, "Current", "current", displayOrder: 0);
        await CreateBookAsync(club.Id, "Future A", "future", displayOrder: 0);

        // Same status AND same DisplayOrder: AddedAt descending breaks the tie, which is the
        // pre-#144 behaviour kept as a safety net for rows never backfilled with an order.
        await CreateBookAsync(club.Id, "Future Older Tie", "future", displayOrder: 1, addedAt: baseTime);
        await CreateBookAsync(club.Id, "Future Newer Tie", "future", displayOrder: 1, addedAt: baseTime.AddDays(1));

        Assert.Equal(
            ["Current", "Future A", "Future B", "Future Newer Tie", "Future Older Tie", "Past"],
            await TitlesInOrder(me));
    }

    [Fact]
    public async Task A_new_book_is_appended_to_the_end_of_the_future_queue()
    {
        // Never the front: adding a book must not jump ahead of an order an admin already set.
        var club = await CreateClubAsync();
        var admin = await CreateUserAsync("Admin", club.Id, isClubAdmin: true);
        await CreateBookAsync(club.Id, "Already Queued", "future", displayOrder: 0);

        var response = await admin.Client.PostAsJsonAsync("/books", new
        {
            club_id = club.Id, title = "Brand New", author = "Someone", cover_url = (string?)null
        });
        Assert.True(response.IsSuccessStatusCode, await response.Content.ReadAsStringAsync());

        Assert.Equal(["Already Queued", "Brand New"], await TitlesInOrder(admin));
    }

    [Fact]
    public async Task Changing_status_appends_to_the_new_group_rather_than_jumping_the_queue()
    {
        var club = await CreateClubAsync();
        var admin = await CreateUserAsync("Admin", club.Id, isClubAdmin: true);
        await CreateBookAsync(club.Id, "Current First", "current", displayOrder: 0);
        var promoted = await CreateBookAsync(club.Id, "Promoted", "future", displayOrder: 0);

        var response = await admin.Client.PatchAsJsonAsync($"/books/{promoted.Id}/status", new { status = "current" });
        Assert.True(response.IsSuccessStatusCode, await response.Content.ReadAsStringAsync());

        Assert.Equal(["Current First", "Promoted"], await TitlesInOrder(admin));
    }

    [Fact]
    public async Task A_no_op_status_write_does_not_reshuffle_the_book()
    {
        var club = await CreateClubAsync();
        var admin = await CreateUserAsync("Admin", club.Id, isClubAdmin: true);
        var first = await CreateBookAsync(club.Id, "First", "current", displayOrder: 0);
        await CreateBookAsync(club.Id, "Second", "current", displayOrder: 1);

        await admin.Client.PatchAsJsonAsync($"/books/{first.Id}/status", new { status = "current" });

        Assert.Equal(["First", "Second"], await TitlesInOrder(admin));
    }

    [Fact]
    public async Task Moving_a_book_to_past_stamps_finished_at_and_moving_it_back_clears_it()
    {
        var club = await CreateClubAsync();
        var admin = await CreateUserAsync("Admin", club.Id, isClubAdmin: true);
        var book = await CreateBookAsync(club.Id, "The Road", "current");

        await admin.Client.PatchAsJsonAsync($"/books/{book.Id}/status", new { status = "past" });
        await using (var db = App.NewDbContext())
            Assert.NotNull((await db.Books.FindAsync(book.Id))!.FinishedAt);

        await admin.Client.PatchAsJsonAsync($"/books/{book.Id}/status", new { status = "current" });
        await using (var db = App.NewDbContext())
            Assert.Null((await db.Books.FindAsync(book.Id))!.FinishedAt);
    }

    [Fact]
    public async Task An_invalid_status_is_refused()
    {
        var club = await CreateClubAsync();
        var admin = await CreateUserAsync("Admin", club.Id, isClubAdmin: true);
        var book = await CreateBookAsync(club.Id, "The Road");

        var response = await admin.Client.PatchAsJsonAsync($"/books/{book.Id}/status", new { status = "reading" });

        // Worth pinning hard. The iOS Book model types `status` as a NON-optional enum with no
        // unknown fallback (unlike MessageType), so a value outside future/current/past reaching
        // the database makes the whole /books response fail to decode and blanks the library.
        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
    }

    // ---- reordering -------------------------------------------------------------------------

    [Fact]
    public async Task Reordering_a_status_group_persists_the_new_order()
    {
        var club = await CreateClubAsync();
        var admin = await CreateUserAsync("Admin", club.Id, isClubAdmin: true);
        var a = await CreateBookAsync(club.Id, "A", "future", displayOrder: 0);
        var b = await CreateBookAsync(club.Id, "B", "future", displayOrder: 1);
        var c = await CreateBookAsync(club.Id, "C", "future", displayOrder: 2);

        var response = await admin.Client.PutAsJsonAsync("/books/read-order", new
        {
            club_id = club.Id, status = "future", ordered_book_ids = new[] { c.Id, a.Id, b.Id }
        });

        Assert.Equal(HttpStatusCode.NoContent, response.StatusCode);
        Assert.Equal(["C", "A", "B"], await TitlesInOrder(admin));
    }

    [Fact]
    public async Task Reordering_with_a_stale_book_set_is_refused_rather_than_partially_applied()
    {
        var club = await CreateClubAsync();
        var admin = await CreateUserAsync("Admin", club.Id, isClubAdmin: true);
        var a = await CreateBookAsync(club.Id, "A", "future", displayOrder: 0);
        var b = await CreateBookAsync(club.Id, "B", "future", displayOrder: 1);
        await CreateBookAsync(club.Id, "C added while you were dragging", "future", displayOrder: 2);

        // The admin's client only knows about A and B — someone added C mid-reorder.
        var response = await admin.Client.PutAsJsonAsync("/books/read-order", new
        {
            club_id = club.Id, status = "future", ordered_book_ids = new[] { b.Id, a.Id }
        });

        // 409, not a partial apply: silently accepting would let a stale client wipe out the
        // group's real membership, and the client's answer is simply to refetch and retry.
        Assert.Equal(HttpStatusCode.Conflict, response.StatusCode);
        Assert.Equal(["A", "B", "C added while you were dragging"], await TitlesInOrder(admin));
    }

    [Fact]
    public async Task The_legacy_future_read_order_route_still_works()
    {
        // A client on a pre-#144 build keeps calling this route for as long as App Store review
        // takes, so it has to keep behaving. Nothing else in the suite would notice its removal.
        var club = await CreateClubAsync();
        var admin = await CreateUserAsync("Admin", club.Id, isClubAdmin: true);
        var a = await CreateBookAsync(club.Id, "A", "future", displayOrder: 0);
        var b = await CreateBookAsync(club.Id, "B", "future", displayOrder: 1);

        var response = await admin.Client.PutAsJsonAsync("/books/future-read-order", new
        {
            club_id = club.Id, ordered_book_ids = new[] { b.Id, a.Id }
        });

        Assert.Equal(HttpStatusCode.NoContent, response.StatusCode);
        Assert.Equal(["B", "A"], await TitlesInOrder(admin));
    }

    [Fact]
    public async Task Series_order_is_persisted_and_a_stale_set_is_refused()
    {
        var club = await CreateClubAsync();
        var admin = await CreateUserAsync("Admin", club.Id, isClubAdmin: true);
        var one = await CreateBookAsync(club.Id, "Book One", "future", seriesName: "Dune", seriesOrder: 0);
        var two = await CreateBookAsync(club.Id, "Book Two", "future", seriesName: "Dune", seriesOrder: 1);

        var ok = await admin.Client.PutAsJsonAsync("/books/series-order", new
        {
            club_id = club.Id, series_name = "Dune", ordered_book_ids = new[] { two.Id, one.Id }
        });
        Assert.Equal(HttpStatusCode.NoContent, ok.StatusCode);

        await using (var db = App.NewDbContext())
        {
            Assert.Equal(1, (await db.Books.FindAsync(one.Id))!.SeriesOrder);
            Assert.Equal(0, (await db.Books.FindAsync(two.Id))!.SeriesOrder);
        }

        var stale = await admin.Client.PutAsJsonAsync("/books/series-order", new
        {
            club_id = club.Id, series_name = "Dune", ordered_book_ids = new[] { one.Id }
        });
        Assert.Equal(HttpStatusCode.Conflict, stale.StatusCode);
    }

    [Fact]
    public async Task Re_saving_the_same_series_does_not_move_the_book_to_the_end_of_it()
    {
        var club = await CreateClubAsync();
        var admin = await CreateUserAsync("Admin", club.Id, isClubAdmin: true);
        var first = await CreateBookAsync(club.Id, "Book One", "future", seriesName: "Dune", seriesOrder: 0);
        await CreateBookAsync(club.Id, "Book Two", "future", seriesName: "Dune", seriesOrder: 1);

        // Editing the title while leaving the series alone must not re-append (#138).
        await admin.Client.PatchAsJsonAsync($"/books/{first.Id}", new
        {
            title = "Book One (revised)", author = "Frank Herbert", series_name = "Dune"
        });

        await using var db = App.NewDbContext();
        Assert.Equal(0, (await db.Books.FindAsync(first.Id))!.SeriesOrder);
    }

    // ---- authorization ----------------------------------------------------------------------

    [Fact]
    public async Task Library_mutations_require_club_admin_while_reading_only_requires_membership()
    {
        var club = await CreateClubAsync();
        var member = await CreateUserAsync("Member", club.Id, isClubAdmin: false);
        var book = await CreateBookAsync(club.Id, "The Road");

        Assert.True((await member.Client.GetAsync("/books")).IsSuccessStatusCode);
        Assert.True((await member.Client.GetAsync($"/books/{book.Id}")).IsSuccessStatusCode);

        foreach (var (label, response) in new[]
        {
            ("create", await member.Client.PostAsJsonAsync("/books", new { club_id = club.Id, title = "New", author = "A", cover_url = (string?)null })),
            ("update", await member.Client.PatchAsJsonAsync($"/books/{book.Id}", new { title = "Renamed", author = "A" })),
            ("status", await member.Client.PatchAsJsonAsync($"/books/{book.Id}/status", new { status = "past" })),
            ("delete", await member.Client.DeleteAsync($"/books/{book.Id}")),
            ("reorder", await member.Client.PutAsJsonAsync("/books/read-order", new { club_id = club.Id, status = "current", ordered_book_ids = new[] { book.Id } })),
        })
        {
            Assert.True(response.StatusCode == HttpStatusCode.Forbidden, $"{label} returned {(int)response.StatusCode}, expected 403");
        }
    }

    [Fact]
    public async Task Deleting_a_book_takes_its_messages_with_it()
    {
        var club = await CreateClubAsync();
        var admin = await CreateUserAsync("Admin", club.Id, isClubAdmin: true);
        var book = await CreateBookAsync(club.Id, "The Road");
        await InsertMessageAsync(book.Id, club.Id, admin.Id);

        var response = await admin.Client.DeleteAsync($"/books/{book.Id}");

        Assert.Equal(HttpStatusCode.NoContent, response.StatusCode);
        await using var db = App.NewDbContext();
        Assert.Equal(0, await db.Messages.CountAsync());
        Assert.Null(await db.Books.FindAsync(book.Id));
    }
}
