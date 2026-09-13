using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using BookClubApi.Models;
using BookClubApi.Tests.Infrastructure;
using Microsoft.EntityFrameworkCore;

namespace BookClubApi.Tests.Api;

/// Admin operations, the destructive ones especially, and the seed endpoints the UI-test lanes
/// depend on.
public class AdminTests(TestAppFixture fixture) : IntegrationTestBase(fixture)
{
    // ---- seeding (used by the live and device lanes) -----------------------------------------

    [Fact]
    public async Task Seed_baseline_creates_one_book_per_status_and_is_idempotent()
    {
        // The UI lanes call this before every run, so "safe to call twice" is load-bearing: it is
        // what stops the dev database growing until seeded messages scroll out of the first page
        // and the tests start failing for reasons that have nothing to do with the app.
        var first = await App.CreateClient().PostAsync("/admin/seed-baseline", null);
        var second = await App.CreateClient().PostAsync("/admin/seed-baseline", null);

        Assert.True(first.IsSuccessStatusCode, await first.Content.ReadAsStringAsync());
        Assert.True(second.IsSuccessStatusCode);

        await using var db = App.NewDbContext();
        Assert.Equal(1, await db.Clubs.CountAsync());
        Assert.Equal(3, await db.Books.CountAsync());
        Assert.Equal(1, await db.Books.CountAsync(b => b.Status == "current"));
        Assert.Equal(1, await db.Books.CountAsync(b => b.Status == "future"));
        Assert.Equal(1, await db.Books.CountAsync(b => b.Status == "past"));
    }

    [Fact]
    public async Task Seed_baseline_reuses_an_existing_club_rather_than_creating_another()
    {
        var club = await CreateClubAsync("Existing Club");

        await App.CreateClient().PostAsync("/admin/seed-baseline", null);

        await using var db = App.NewDbContext();
        Assert.Equal(1, await db.Clubs.CountAsync());
        Assert.Equal(3, await db.Books.CountAsync(b => b.ClubId == club.Id));
    }

    [Fact]
    public async Task Seed_messages_accepts_the_seed_key_from_a_non_admin()
    {
        // Worth being precise about, because it constrains the lane scripts: AdminController
        // carries a class-level [Authorize] and seed-messages does NOT opt out with
        // [AllowAnonymous] (unlike seed-baseline). So X-Seed-Key is not an anonymous back door —
        // it substitutes for ADMIN rights, not for authentication. A lane script needs both a
        // bearer token and the key.
        var club = await CreateClubAsync();
        await CreateBookAsync(club.Id, "Seed: Current Read");
        // The sender is resolved by DISPLAY NAME, and the endpoint 404s if it finds nobody. The
        // lane scripts have to create the seed account first; pinning that here means a change to
        // the resolution rule surfaces as a test failure rather than as a broken lane script.
        await CreateUserAsync("Seeded Sender", club.Id);
        var nonAdmin = await CreateUserAsync("Ordinary Member", club.Id);

        var request = new HttpRequestMessage(HttpMethod.Post, "/admin/seed-messages")
        {
            Content = JsonBody(new { bookTitle = "Current Read", count = 3, senderName = "Seeded Sender", type = "text" })
        };
        request.Headers.Add("X-Seed-Key", ApiFactory.SeedingKey);

        var response = await nonAdmin.Client.SendAsync(request);

        Assert.True(response.IsSuccessStatusCode, $"{(int)response.StatusCode}: {await response.Content.ReadAsStringAsync()}");
        await using var db = App.NewDbContext();
        Assert.Equal(3, await db.Messages.CountAsync());
    }

    [Fact]
    public async Task Seed_messages_without_the_key_or_admin_rights_is_refused()
    {
        var club = await CreateClubAsync();
        await CreateBookAsync(club.Id, "Seed: Current Read");
        var member = await CreateUserAsync("Member", club.Id);

        var response = await member.Client.PostAsync("/admin/seed-messages",
            JsonBody(new { bookTitle = "Current Read", count = 1, type = "text" }));

        Assert.Equal(HttpStatusCode.Forbidden, response.StatusCode);
    }

    [Fact]
    public async Task Seed_messages_is_not_reachable_anonymously()
    {
        // Pins the boundary the test above describes. The security backlog in CLAUDE.md records
        // seed-messages as "reachable unauthenticated and gated only by an X-Seed-Key header";
        // the class-level [Authorize] means that is not actually true, and this keeps it true.
        var club = await CreateClubAsync();
        await CreateBookAsync(club.Id, "Seed: Current Read");

        var request = new HttpRequestMessage(HttpMethod.Post, "/admin/seed-messages")
        {
            Content = JsonBody(new { bookTitle = "Current Read", count = 1, type = "text" })
        };
        request.Headers.Add("X-Seed-Key", ApiFactory.SeedingKey);

        var response = await App.CreateClient().SendAsync(request);

        Assert.Equal(HttpStatusCode.Unauthorized, response.StatusCode);
    }

    [Fact]
    public async Task Seeded_messages_are_back_dated_so_their_order_is_deterministic()
    {
        var club = await CreateClubAsync();
        await CreateBookAsync(club.Id, "Seed: Current Read");
        await CreateUserAsync("Seeded Sender", club.Id);
        var caller = await CreateUserAsync("Caller", club.Id);

        var request = new HttpRequestMessage(HttpMethod.Post, "/admin/seed-messages")
        {
            Content = JsonBody(new { bookTitle = "Current Read", count = 3, senderName = "Seeded Sender", type = "text" })
        };
        request.Headers.Add("X-Seed-Key", ApiFactory.SeedingKey);
        var seeded = await caller.Client.SendAsync(request);
        Assert.True(seeded.IsSuccessStatusCode, await seeded.Content.ReadAsStringAsync());

        await using var db = App.NewDbContext();
        var sentAts = await db.Messages.OrderBy(m => m.SentAt).Select(m => m.SentAt).ToListAsync();

        // Distinct timestamps, one second apart. Identical SentAt values would make the chat's
        // ordering — and any test asserting on it — depend on insertion order.
        Assert.Equal(3, sentAts.Distinct().Count());
    }

    // ---- dev database reset (#126, used by the live and device lanes) -------------------------

    [Fact]
    public async Task Reset_dev_db_empties_every_table()
    {
        var club = await CreateClubAsync();
        var book = await CreateBookAsync(club.Id, "The Road");
        var me = await CreateUserAsync("Me", club.Id);
        var other = await CreateUserAsync("Other", club.Id);
        var message = await InsertMessageAsync(book.Id, club.Id, other.Id, MessageType.Voice);
        await RegisterDeviceAsync(me.Id, "some-device");
        await me.Client.PostAsync($"/books/{book.Id}/messages/{message.Id}/heard", null);
        await me.Client.PostAsJsonAsync($"/books/{book.Id}/messages/{message.Id}/reactions", new { emoji = "👍" });
        await me.Client.PostAsJsonAsync($"/books/{book.Id}/read", message.Id);
        await me.Client.PostAsync($"/messages/{message.Id}/save", null);
        await me.Client.PostAsync($"/messages/{message.Id}/report", null);
        await me.Client.PostAsync($"/users/{other.Id}/block", null);

        var response = await ResetAsync(ApiFactory.SeedingKey);

        Assert.True(response.IsSuccessStatusCode, await response.Content.ReadAsStringAsync());
        await using var db = App.NewDbContext();
        // Named individually rather than looped, so a NEW table added later fails to compile here
        // and forces a decision about whether the reset should clear it.
        Assert.Empty(db.MessageReactions);
        Assert.Empty(db.MessageHeards);
        Assert.Empty(db.ChatReads);
        Assert.Empty(db.Reports);
        Assert.Empty(db.SavedMessages);
        Assert.Empty(db.Messages);
        Assert.Empty(db.Books);
        Assert.Empty(db.JoinRequests);
        Assert.Empty(db.BlockedUsers);
        Assert.Empty(db.UserDevices);
        Assert.Empty(db.RefreshTokens);
        Assert.Empty(db.Memberships);
        Assert.Empty(db.Users);
        Assert.Empty(db.Clubs);
    }

    [Fact]
    public async Task Reset_dev_db_refuses_a_wrong_or_missing_key()
    {
        var club = await CreateClubAsync();

        Assert.Equal(HttpStatusCode.Unauthorized, (await ResetAsync("wrong-key")).StatusCode);
        Assert.Equal(HttpStatusCode.Unauthorized, (await ResetAsync(null)).StatusCode);

        // Two independent gates guard this endpoint (Development-only AND the key) because a
        // truncate that reached production would be unrecoverable. The environment gate cannot be
        // exercised here — the test host runs as Development on purpose, so the seed endpoints
        // behave as they do locally — so the key gate is the half this pins.
        await using var db = App.NewDbContext();
        Assert.NotNull(await db.Clubs.FindAsync(club.Id));
    }

    [Fact]
    public async Task Reset_then_seed_leaves_exactly_the_baseline()
    {
        // The sequence the lane scripts run before every live pass.
        var club = await CreateClubAsync();
        await CreateBookAsync(club.Id, "Left over from the last run");

        await ResetAsync(ApiFactory.SeedingKey);
        await App.CreateClient().PostAsync("/admin/seed-baseline", null);

        await using var db = App.NewDbContext();
        Assert.Equal(3, await db.Books.CountAsync());
        Assert.Equal(1, await db.Clubs.CountAsync());
        Assert.False(await db.Books.AnyAsync(b => b.Title == "Left over from the last run"));
    }

    private async Task<HttpResponseMessage> ResetAsync(string? key)
    {
        var request = new HttpRequestMessage(HttpMethod.Post, "/admin/reset-dev-db");
        if (key is not null) request.Headers.Add("X-Seed-Key", key);
        return await App.CreateClient().SendAsync(request);
    }

    // ---- user administration -----------------------------------------------------------------

    [Fact]
    public async Task Only_a_global_admin_can_reach_the_admin_endpoints()
    {
        var club = await CreateClubAsync();
        var clubAdmin = await CreateUserAsync("Club Admin", club.Id, isClubAdmin: true);
        var pending = await CreateUserAsync("Pending", club.Id, approved: false);

        // Club-admin is not global-admin. That distinction is the whole point of having both.
        foreach (var (label, response) in new[]
        {
            ("pending-users", await clubAdmin.Client.GetAsync("/admin/pending-users")),
            ("approve", await clubAdmin.Client.PostAsync($"/admin/users/{pending.Id}/approve", null)),
            ("delete user", await clubAdmin.Client.DeleteAsync($"/admin/users/{pending.Id}")),
            ("delete club", await clubAdmin.Client.DeleteAsync($"/admin/clubs/{club.Id}")),
        })
        {
            Assert.True(response.StatusCode == HttpStatusCode.Forbidden, $"{label} returned {(int)response.StatusCode}");
        }
    }

    [Fact]
    public async Task Approving_a_user_lets_them_send()
    {
        var club = await CreateClubAsync();
        var book = await CreateBookAsync(club.Id, "The Road");
        var admin = await CreateUserAsync("Admin", club.Id, isAdmin: true);
        var pending = await CreateUserAsync("Pending", club.Id, approved: false);

        var before = await pending.Client.PostAsJsonAsync($"/books/{book.Id}/messages",
            new { type = "Text", body = "hello", client_id = Guid.NewGuid() });
        Assert.Equal(HttpStatusCode.BadRequest, before.StatusCode);

        await admin.Client.PostAsync($"/admin/users/{pending.Id}/approve", null);

        var after = await pending.Client.PostAsJsonAsync($"/books/{book.Id}/messages",
            new { type = "Text", body = "hello", client_id = Guid.NewGuid() });
        Assert.True(after.IsSuccessStatusCode, await after.Content.ReadAsStringAsync());
    }

    [Fact]
    public async Task An_admin_cannot_delete_or_demote_themselves()
    {
        var club = await CreateClubAsync();
        var admin = await CreateUserAsync("Admin", club.Id, isAdmin: true);

        var deleteSelf = await admin.Client.DeleteAsync($"/admin/users/{admin.Id}");
        var demoteSelf = await admin.Client.PostAsJsonAsync($"/admin/users/{admin.Id}/set-role", new { is_admin = false });

        // Locking yourself out of the only admin account is unrecoverable without database access.
        Assert.Equal(HttpStatusCode.BadRequest, deleteSelf.StatusCode);
        Assert.Equal(HttpStatusCode.BadRequest, demoteSelf.StatusCode);
    }

    [Fact(Skip = "Blocked: DELETE /admin/users/{id} throws for every user — see the note below.")]
    public async Task Deleting_a_user_removes_everything_that_references_them()
    {
        var club = await CreateClubAsync();
        var book = await CreateBookAsync(club.Id, "The Road");
        var admin = await CreateUserAsync("Admin", club.Id, isAdmin: true);
        var doomed = await CreateUserAsync("Doomed", club.Id);
        var bystander = await CreateUserAsync("Bystander", club.Id);

        var theirMessage = await InsertMessageAsync(book.Id, club.Id, doomed.Id);
        var bystanderMessage = await InsertMessageAsync(book.Id, club.Id, bystander.Id);
        await bystander.Client.PostAsync($"/messages/{theirMessage.Id}/save", null);
        await bystander.Client.PostAsync($"/messages/{theirMessage.Id}/report", null);
        await doomed.Client.PostAsync($"/messages/{bystanderMessage.Id}/save", null);
        await doomed.Client.PostAsync($"/users/{bystander.Id}/block", null);

        var response = await admin.Client.DeleteAsync($"/admin/users/{doomed.Id}");

        Assert.Equal(HttpStatusCode.NoContent, response.StatusCode);
        await using var db = App.NewDbContext();
        Assert.Null(await db.Users.FindAsync(doomed.Id));
        Assert.Empty(await db.Messages.Where(m => m.SenderId == doomed.Id).ToListAsync());
        Assert.Empty(await db.SavedMessages.Where(s => s.UserId == doomed.Id || s.MessageId == theirMessage.Id).ToListAsync());
        Assert.Empty(await db.Reports.Where(r => r.ReporterId == doomed.Id || r.MessageId == theirMessage.Id).ToListAsync());
        Assert.Empty(await db.BlockedUsers.Where(b => b.BlockerId == doomed.Id || b.BlockedId == doomed.Id).ToListAsync());
        Assert.Empty(await db.Memberships.Where(m => m.UserId == doomed.Id).ToListAsync());

        // The bystander is untouched — deletion must be surgical, not a blast radius.
        Assert.NotNull(await db.Messages.FindAsync(bystanderMessage.Id));
    }

    // Both delete-user tests are skipped, for two SEPARATE bugs found while writing them:
    //
    // 1. Unconditional: DeleteUser calls db.Database.BeginTransactionAsync(), but the DbContext is
    //    registered with EnableRetryOnFailure (Program.cs). EF rejects that pairing at runtime —
    //    "The configured execution strategy 'SqlServerRetryingExecutionStrategy' does not support
    //    user-initiated transactions" — so the endpoint 500s for EVERY user, not just the case in
    //    #133. Fix is to wrap the work in db.Database.CreateExecutionStrategy().ExecuteAsync(...).
    //
    // 2. #133 on top of that: the deletion order never clears MessageHeards or MessageReactions,
    //    which are DeleteBehavior.NoAction, so even once (1) is fixed a user who has played a
    //    voice message or tapped a reaction still trips a foreign-key violation.
    //
    // Unskip the first test when (1) is fixed and the second when (2) is.
    [Fact(Skip = "Reproduces open bug #133, and is also blocked by the execution-strategy bug above.")]
    public async Task Deleting_a_user_who_has_heard_or_reacted_to_a_message_succeeds()
    {
        // #133: the deletion order in AdminController.DeleteUser never clears MessageHeards or
        // MessageReactions, and those relationships are DeleteBehavior.NoAction, so removing the
        // user trips a foreign-key violation and the whole transaction rolls back. In practice
        // that means any member who has ever played a voice message or tapped a reaction — which
        // is all of them — cannot be deleted at all.
        var club = await CreateClubAsync();
        var book = await CreateBookAsync(club.Id, "The Road");
        var admin = await CreateUserAsync("Admin", club.Id, isAdmin: true);
        var doomed = await CreateUserAsync("Doomed", club.Id);
        var other = await CreateUserAsync("Other", club.Id);

        var voice = await InsertMessageAsync(book.Id, club.Id, other.Id, MessageType.Voice);
        await doomed.Client.PostAsync($"/books/{book.Id}/messages/{voice.Id}/heard", null);
        await doomed.Client.PostAsJsonAsync($"/books/{book.Id}/messages/{voice.Id}/reactions", new { emoji = "👍" });

        var response = await admin.Client.DeleteAsync($"/admin/users/{doomed.Id}");

        Assert.Equal(HttpStatusCode.NoContent, response.StatusCode);
    }

    // ---- join requests -----------------------------------------------------------------------

    [Fact]
    public async Task A_declined_join_request_is_reset_to_pending_when_the_user_asks_again()
    {
        var club = await CreateClubAsync();
        var admin = await CreateUserAsync("Admin", club.Id, isAdmin: true, isClubAdmin: true);
        var hopeful = await CreateUserAsync("Hopeful");

        await hopeful.Client.PostAsync($"/clubs/{club.Id}/join-request", null);
        var requests = await ReadAsync<List<JsonElement>>(await admin.Client.GetAsync("/admin/join-requests"));
        var requestId = requests[0].GetProperty("id").GetGuid();
        await admin.Client.PostAsync($"/admin/join-requests/{requestId}/decline", null);

        // Asking again after a decline must reopen the same request rather than being silently
        // swallowed — otherwise a declined user can never get back in.
        await hopeful.Client.PostAsync($"/clubs/{club.Id}/join-request", null);

        await using var db = App.NewDbContext();
        var request = await db.JoinRequests.SingleAsync(jr => jr.UserId == hopeful.Id);
        Assert.Equal(JoinRequestStatus.Pending, request.Status);
    }

    [Fact]
    public async Task Requesting_to_join_a_club_you_are_already_in_is_a_conflict()
    {
        var club = await CreateClubAsync();
        var member = await CreateUserAsync("Member", club.Id);

        var response = await member.Client.PostAsync($"/clubs/{club.Id}/join-request", null);

        Assert.Equal(HttpStatusCode.Conflict, response.StatusCode);
    }

    [Fact]
    public async Task Approving_a_join_request_makes_the_user_a_member()
    {
        var club = await CreateClubAsync();
        var admin = await CreateUserAsync("Admin", club.Id, isAdmin: true, isClubAdmin: true);
        var hopeful = await CreateUserAsync("Hopeful");

        await hopeful.Client.PostAsync($"/clubs/{club.Id}/join-request", null);
        var requests = await ReadAsync<List<JsonElement>>(await admin.Client.GetAsync("/admin/join-requests"));
        var requestId = requests[0].GetProperty("id").GetGuid();

        var response = await admin.Client.PostAsync($"/admin/join-requests/{requestId}/approve", null);

        Assert.True(response.IsSuccessStatusCode, await response.Content.ReadAsStringAsync());
        await using var db = App.NewDbContext();
        Assert.True(await db.Memberships.AnyAsync(m => m.UserId == hopeful.Id && m.ClubId == club.Id));
    }
}
