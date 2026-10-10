using BookClubApi.Data;
using BookClubApi.Models;
using BookClubApi.Tests.Infrastructure;
using Microsoft.Data.SqlClient;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Infrastructure;
using Microsoft.EntityFrameworkCore.Migrations;

namespace BookClubApi.Tests.Api;

/// #204 (A18) — the AddMessageReceivedAt migration against existing rows. Every other test runs on
/// a database migrated while empty, where a missing backfill is invisible: the column's SQL
/// default would give every existing message the deploy time, and unread counts — now comparing
/// arrival times — would treat everything after a reader's marker as read.
///
/// Runs on its own database in the same container, so taking the schema down and back up can't
/// disturb the shared one.
public class ReceivedAtMigrationTests(TestAppFixture fixture) : IntegrationTestBase(fixture)
{
    private const string Previous = "20260903161321_RenameFutureReadOrderToDisplayOrder";
    private const string Target = "AddMessageReceivedAt";

    [Fact]
    public async Task Existing_messages_get_their_sent_time_as_their_arrival_time()
    {
        var connection = new SqlConnectionStringBuilder(Fixture.Sql.ConnectionString)
        {
            InitialCatalog = "ombc_migration_" + Guid.NewGuid().ToString("N")[..8]
        }.ConnectionString;
        var options = new DbContextOptionsBuilder<AppDbContext>().UseSqlServer(connection).Options;

        await using var db = new AppDbContext(options);
        try
        {
            await db.Database.MigrateAsync();
            Assert.EndsWith(Target, (await db.Database.GetAppliedMigrationsAsync()).Last());

            var club = new Club { Name = "Club" };
            var user = new User { AppleSubject = "migration_test", DisplayName = "Mark", IsApproved = true };
            db.AddRange(club, user);
            await db.SaveChangesAsync();
            var book = new Book { ClubId = club.Id, Title = "The Road", Author = "McCarthy", Status = "current" };
            db.Add(book);
            await db.SaveChangesAsync();
            var sentTimes = new[] { new DateTime(2026, 6, 1, 9, 0, 0), new DateTime(2026, 9, 30, 21, 15, 0) };
            foreach (var sent in sentTimes)
                db.Add(new Message { ClubId = club.Id, BookId = book.Id, SenderId = user.Id, Type = MessageType.Text, Body = "hi", SentAt = sent });
            await db.SaveChangesAsync();

            // Back to the schema before the column existed (drops it), then forward again: the
            // same thing production's startup migration does to its existing rows.
            var migrator = db.GetService<IMigrator>();
            await migrator.MigrateAsync(Previous);
            await migrator.MigrateAsync();

            db.ChangeTracker.Clear();
            var rows = await db.Messages.OrderBy(m => m.SentAt).Select(m => new { m.SentAt, m.ReceivedAt }).ToListAsync();
            Assert.Equal(sentTimes, rows.Select(r => r.SentAt));
            Assert.All(rows, r => Assert.Equal(r.SentAt, r.ReceivedAt));
        }
        finally
        {
            await db.Database.EnsureDeletedAsync();
        }
    }
}
