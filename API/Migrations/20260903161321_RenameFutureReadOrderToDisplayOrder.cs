using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace BookClubApi.Migrations
{
    /// <inheritdoc />
    public partial class RenameFutureReadOrderToDisplayOrder : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.RenameColumn(
                name: "FutureReadOrder",
                table: "Books",
                newName: "DisplayOrder");

            // #144 — backfill DisplayOrder for existing current/past books (previously unused,
            // always 0) from their current display order — AddedAt descending, newest first,
            // matching GetMyBooks' pre-#144 tie-break — so switching those groups onto manual
            // ordering doesn't visibly reshuffle anything until an admin actually reorders.
            // future rows keep the FutureReadOrder values the rename preserved.
            migrationBuilder.Sql(@"
                ;WITH ranked AS (
                    SELECT Id, ROW_NUMBER() OVER (PARTITION BY ClubId, Status ORDER BY AddedAt DESC) - 1 AS rn
                    FROM Books
                    WHERE Status IN ('current', 'past')
                )
                UPDATE b
                SET b.DisplayOrder = ranked.rn
                FROM Books b
                JOIN ranked ON b.Id = ranked.Id;
            ");
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.RenameColumn(
                name: "DisplayOrder",
                table: "Books",
                newName: "FutureReadOrder");
        }
    }
}
