using System;
using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace BookClubApi.Migrations
{
    /// <inheritdoc />
    public partial class VideoSlots : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropIndex(
                name: "IX_PendingVideos_SenderId_ClientId",
                table: "PendingVideos");

            migrationBuilder.AlterColumn<Guid>(
                name: "ClientId",
                table: "PendingVideos",
                type: "uniqueidentifier",
                nullable: true,
                oldClrType: typeof(Guid),
                oldType: "uniqueidentifier");

            migrationBuilder.AlterColumn<Guid>(
                name: "BookId",
                table: "PendingVideos",
                type: "uniqueidentifier",
                nullable: true,
                oldClrType: typeof(Guid),
                oldType: "uniqueidentifier");

            migrationBuilder.AddColumn<Guid>(
                name: "ClubId",
                table: "PendingVideos",
                type: "uniqueidentifier",
                nullable: true);

            migrationBuilder.AddColumn<Guid>(
                name: "SessionId",
                table: "PendingVideos",
                type: "uniqueidentifier",
                nullable: true);

            migrationBuilder.CreateIndex(
                name: "IX_PendingVideos_SenderId_ClientId",
                table: "PendingVideos",
                columns: new[] { "SenderId", "ClientId" },
                unique: true,
                filter: "[ClientId] IS NOT NULL");
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropIndex(
                name: "IX_PendingVideos_SenderId_ClientId",
                table: "PendingVideos");

            migrationBuilder.DropColumn(
                name: "ClubId",
                table: "PendingVideos");

            migrationBuilder.DropColumn(
                name: "SessionId",
                table: "PendingVideos");

            migrationBuilder.AlterColumn<Guid>(
                name: "ClientId",
                table: "PendingVideos",
                type: "uniqueidentifier",
                nullable: false,
                defaultValue: new Guid("00000000-0000-0000-0000-000000000000"),
                oldClrType: typeof(Guid),
                oldType: "uniqueidentifier",
                oldNullable: true);

            migrationBuilder.AlterColumn<Guid>(
                name: "BookId",
                table: "PendingVideos",
                type: "uniqueidentifier",
                nullable: false,
                defaultValue: new Guid("00000000-0000-0000-0000-000000000000"),
                oldClrType: typeof(Guid),
                oldType: "uniqueidentifier",
                oldNullable: true);

            migrationBuilder.CreateIndex(
                name: "IX_PendingVideos_SenderId_ClientId",
                table: "PendingVideos",
                columns: new[] { "SenderId", "ClientId" },
                unique: true);
        }
    }
}
