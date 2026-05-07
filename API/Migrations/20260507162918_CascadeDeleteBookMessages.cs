using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace BookClubApi.Migrations
{
    /// <inheritdoc />
    public partial class CascadeDeleteBookMessages : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropForeignKey(
                name: "FK_Messages_Books_BookId",
                table: "Messages");

            migrationBuilder.AddForeignKey(
                name: "FK_Messages_Books_BookId",
                table: "Messages",
                column: "BookId",
                principalTable: "Books",
                principalColumn: "Id",
                onDelete: ReferentialAction.Cascade);
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropForeignKey(
                name: "FK_Messages_Books_BookId",
                table: "Messages");

            migrationBuilder.AddForeignKey(
                name: "FK_Messages_Books_BookId",
                table: "Messages",
                column: "BookId",
                principalTable: "Books",
                principalColumn: "Id");
        }
    }
}
