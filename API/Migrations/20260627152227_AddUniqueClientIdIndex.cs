using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace BookClubApi.Migrations
{
    /// <inheritdoc />
    public partial class AddUniqueClientIdIndex : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropIndex(
                name: "IX_Messages_ClientId",
                table: "Messages");

            migrationBuilder.DropIndex(
                name: "IX_Messages_SenderId",
                table: "Messages");

            // Any pre-existing duplicate (SenderId, ClientId) rows — created by the
            // check-then-insert race this index closes — would make the unique index fail
            // to build. Keep the earliest row in each group and NULL the clientId on the
            // rest. We deliberately do NOT delete the duplicate messages (they may have
            // replies/saves/heard records and were already shown to users); nulling ClientId
            // just removes them from this filtered index and is functionally inert, since
            // ClientId is only used for live echo-matching at send time.
            migrationBuilder.Sql(@"
                WITH ranked AS (
                    SELECT Id,
                           ROW_NUMBER() OVER (PARTITION BY SenderId, ClientId ORDER BY SentAt, Id) AS rn
                    FROM Messages
                    WHERE ClientId IS NOT NULL
                )
                UPDATE Messages
                SET ClientId = NULL
                WHERE Id IN (SELECT Id FROM ranked WHERE rn > 1);");

            migrationBuilder.CreateIndex(
                name: "IX_Messages_SenderId_ClientId",
                table: "Messages",
                columns: new[] { "SenderId", "ClientId" },
                unique: true,
                filter: "[ClientId] IS NOT NULL");
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropIndex(
                name: "IX_Messages_SenderId_ClientId",
                table: "Messages");

            migrationBuilder.CreateIndex(
                name: "IX_Messages_ClientId",
                table: "Messages",
                column: "ClientId",
                filter: "[ClientId] IS NOT NULL");

            migrationBuilder.CreateIndex(
                name: "IX_Messages_SenderId",
                table: "Messages",
                column: "SenderId");
        }
    }
}
