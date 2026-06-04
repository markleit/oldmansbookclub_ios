using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace BookClubApi.Migrations
{
    /// <inheritdoc />
    public partial class MigrateToPreferencesJson : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.AddColumn<string>(
                name: "Preferences",
                table: "Users",
                type: "nvarchar(max)",
                nullable: false,
                defaultValue: "{}");

            // Copy existing TapToTalk values into the JSON Preferences column
            migrationBuilder.Sql(@"
                UPDATE [Users]
                SET [Preferences] = CASE WHEN [TapToTalk] = 1
                    THEN '{""TapToTalk"":true}'
                    ELSE '{""TapToTalk"":false}'
                END
            ");

            migrationBuilder.DropColumn(
                name: "TapToTalk",
                table: "Users");
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropColumn(
                name: "Preferences",
                table: "Users");

            migrationBuilder.AddColumn<bool>(
                name: "TapToTalk",
                table: "Users",
                type: "bit",
                nullable: false,
                defaultValue: false);
        }
    }
}
