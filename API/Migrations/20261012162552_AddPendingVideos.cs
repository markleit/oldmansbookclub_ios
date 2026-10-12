using System;
using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace BookClubApi.Migrations
{
    /// <inheritdoc />
    public partial class AddPendingVideos : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.CreateTable(
                name: "PendingVideos",
                columns: table => new
                {
                    Id = table.Column<Guid>(type: "uniqueidentifier", nullable: false),
                    SenderId = table.Column<Guid>(type: "uniqueidentifier", nullable: false),
                    BookId = table.Column<Guid>(type: "uniqueidentifier", nullable: false),
                    ClientId = table.Column<Guid>(type: "uniqueidentifier", nullable: false),
                    MediaUrl = table.Column<string>(type: "nvarchar(512)", maxLength: 512, nullable: false),
                    ParentMessageId = table.Column<Guid>(type: "uniqueidentifier", nullable: true),
                    DeviceId = table.Column<string>(type: "nvarchar(512)", maxLength: 512, nullable: true),
                    SentAt = table.Column<DateTime>(type: "datetime2", nullable: true),
                    CreatedAt = table.Column<DateTime>(type: "datetime2", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_PendingVideos", x => x.Id);
                    table.ForeignKey(
                        name: "FK_PendingVideos_Users_SenderId",
                        column: x => x.SenderId,
                        principalTable: "Users",
                        principalColumn: "Id",
                        onDelete: ReferentialAction.Cascade);
                });

            migrationBuilder.CreateIndex(
                name: "IX_PendingVideos_MediaUrl",
                table: "PendingVideos",
                column: "MediaUrl",
                unique: true);

            migrationBuilder.CreateIndex(
                name: "IX_PendingVideos_SenderId_ClientId",
                table: "PendingVideos",
                columns: new[] { "SenderId", "ClientId" },
                unique: true);
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropTable(
                name: "PendingVideos");
        }
    }
}
