using System;
using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace BookClubApi.Migrations
{
    /// <inheritdoc />
    public partial class AddMessageReceivedAt : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.AddColumn<DateTime>(
                name: "ReceivedAt",
                table: "Messages",
                type: "datetime2",
                nullable: false,
                defaultValueSql: "SYSUTCDATETIME()");

            // #204 — every existing message arrived when it was sent (no client stamped a time
            // before this), so ReceivedAt = SentAt. Without this backfill every row would carry the
            // deploy time: identical arrival times for the whole history, and unread counts — which
            // now compare arrival times — would treat everything after a reader's marker as read.
            migrationBuilder.Sql("UPDATE [Messages] SET [ReceivedAt] = [SentAt];");

            migrationBuilder.CreateIndex(
                name: "IX_Messages_BookId_ReceivedAt",
                table: "Messages",
                columns: new[] { "BookId", "ReceivedAt" });
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropIndex(
                name: "IX_Messages_BookId_ReceivedAt",
                table: "Messages");

            migrationBuilder.DropColumn(
                name: "ReceivedAt",
                table: "Messages");
        }
    }
}
