using System;
using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace BookClubApi.Migrations
{
    /// <inheritdoc />
    public partial class AddMessageClientId : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.AddColumn<Guid>(
                name: "ClientId",
                table: "Messages",
                type: "uniqueidentifier",
                nullable: true);
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropColumn(
                name: "ClientId",
                table: "Messages");
        }
    }
}
