using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace BookClubApi.Migrations
{
    /// <inheritdoc />
    public partial class AddBookFutureReadOrder : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.AddColumn<int>(
                name: "FutureReadOrder",
                table: "Books",
                type: "int",
                nullable: false,
                defaultValue: 0);

            // #137 — seed the new manual order from today's implicit newest-first display order,
            // per club, so existing queues don't collapse to all-zero (undefined tiebreak) the
            // moment this ships.
            migrationBuilder.Sql(@"
                WITH ranked AS (
                    SELECT Id, ROW_NUMBER() OVER (PARTITION BY ClubId ORDER BY AddedAt DESC) - 1 AS rn
                    FROM Books
                    WHERE Status = 'future'
                )
                UPDATE Books
                SET FutureReadOrder = ranked.rn
                FROM Books
                JOIN ranked ON ranked.Id = Books.Id");
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropColumn(
                name: "FutureReadOrder",
                table: "Books");
        }
    }
}
