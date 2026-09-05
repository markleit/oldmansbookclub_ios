using System.Text.Json;
using System.Text.Json.Serialization;
using BookClubApi.Models;
using BookClubApi.Tests.Infrastructure;
using Microsoft.AspNetCore.SignalR;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Options;

namespace BookClubApi.Tests.Api;

/// Generates the JSON fixtures the iOS contract tests decode, and fails if the committed ones no
/// longer match what the server would actually send.
///
/// The drift this exists to catch is specific and real. The server emits ONE MessageDto over TWO
/// transports with TWO naming policies — snake_case over REST (Program.cs), camelCase over SignalR
/// — and Swift has TWO independent mirrors of it: `Message` in Models.swift (tolerant,
/// decodeIfPresent everywhere) and `ChatMessageDto` in ChatService.swift (narrower, non-optional
/// flags, a different date parser, no avatar, no reactions). Nothing connects those four things.
/// A renamed field, an added JsonNamingPolicy on the enum converter, a date format change: each
/// compiles cleanly on both sides and breaks one transport at runtime.
///
/// Regenerate deliberately, never automatically:  OMBC_UPDATE_CONTRACT=1 dotnet test
public class ContractFixtureTests(TestAppFixture fixture) : IntegrationTestBase(fixture)
{
    private static readonly string FixtureDirectory =
        Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "..", "contract");

    /// The options the RUNNING APPLICATION is configured with, pulled out of its own DI container
    /// rather than re-declared here. That distinction is the whole value of this test: a copy of
    /// Program.cs's configuration would keep producing identical fixtures after someone changed
    /// Program.cs, and the drift would reach a device instead of a build.
    private JsonSerializerOptions Rest => Indented(
        App.Services.GetRequiredService<IOptions<Microsoft.AspNetCore.Mvc.JsonOptions>>()
            .Value.JsonSerializerOptions);

    private JsonSerializerOptions SignalR => Indented(
        App.Services.GetRequiredService<IOptions<JsonHubProtocolOptions>>()
            .Value.PayloadSerializerOptions);

    /// A copy, so the fixtures are readable without mutating the options the app is serving with.
    private static JsonSerializerOptions Indented(JsonSerializerOptions source) =>
        new(source) { WriteIndented = true };

    private static readonly Guid MessageId = Guid.Parse("11111111-1111-1111-1111-111111111111");
    private static readonly Guid ClubId = Guid.Parse("22222222-2222-2222-2222-222222222222");
    private static readonly Guid SenderId = Guid.Parse("33333333-3333-3333-3333-333333333333");
    private static readonly Guid ClientId = Guid.Parse("44444444-4444-4444-4444-444444444444");
    private static readonly Guid ParentId = Guid.Parse("55555555-5555-5555-5555-555555555555");
    private static readonly Guid BookId = Guid.Parse("66666666-6666-6666-6666-666666666666");
    private static readonly Guid UserId = Guid.Parse("77777777-7777-7777-7777-777777777777");

    /// Deliberately fractional and deliberately not on a second boundary: the pagination cursor
    /// round-trips through this format, and a client that drops the milliseconds silently skips
    /// every message sent in the same second as the cursor.
    private static readonly DateTime SentAt = new(2026, 9, 4, 15, 30, 45, 123, DateTimeKind.Utc);

    private Dictionary<string, string> BuildFixtures()
    {
        var voice = new MessageDto(
            MessageId, ClubId, SenderId, "Mark", "https://storage.example/avatars/mark.jpg?sig=x",
            MessageType.Voice, null, "https://storage.example/club-media/voice.m4a?sig=x", 42,
            SentAt, false, false, ClientId, ParentId, "Dixie", "🎤 the first words of the reply",
            SentAt.AddMinutes(-5), "an on-device transcript",
            [new MessageReactionDto(UserId, "👍")]);

        // The tombstone shape: every content field nulled, SentAt and the flags kept. Both Swift
        // mirrors have to survive this, and one of them types isDeleted as non-optional.
        var deleted = new MessageDto(
            MessageId, ClubId, Guid.Empty, "", null, MessageType.Text,
            null, null, null, SentAt, true, false, null, null, null, null, null, null, null);

        // The narrow shape ClubsController.GetMessages returns: same Swift type, far fewer fields.
        var minimal = new MessageDto(
            MessageId, ClubId, SenderId, "Mark", null, MessageType.Text, "hello", null, null,
            SentAt, false, false);

        var book = new BookDto(BookId, ClubId, "The Road", "Cormac McCarthy",
            "https://storage.example/covers/road.jpg", SentAt, null, "current",
            "A father and his son walk alone.", 2006, 287, UnreadCount: 3,
            SeriesName: "Border Trilogy", SeriesOrder: 2);

        var user = new UserDto(UserId, "Mark", "Marky", "https://storage.example/avatars/mark.jpg",
            true, false, new UserPreferencesDto(true));

        return new Dictionary<string, string>
        {
            ["message_voice_rest.json"] = JsonSerializer.Serialize(voice, Rest),
            ["message_voice_signalr.json"] = JsonSerializer.Serialize(voice, SignalR),
            ["message_deleted_rest.json"] = JsonSerializer.Serialize(deleted, Rest),
            ["message_deleted_signalr.json"] = JsonSerializer.Serialize(deleted, SignalR),
            ["message_minimal_rest.json"] = JsonSerializer.Serialize(minimal, Rest),
            ["book_rest.json"] = JsonSerializer.Serialize(book, Rest),
            ["user_rest.json"] = JsonSerializer.Serialize(user, Rest),
        };
    }

    [Fact]
    public void The_committed_fixtures_still_match_what_the_server_would_send()
    {
        Directory.CreateDirectory(FixtureDirectory);
        var updating = Environment.GetEnvironmentVariable("OMBC_UPDATE_CONTRACT") == "1";
        var drifted = new List<string>();

        foreach (var (name, json) in BuildFixtures())
        {
            var path = Path.Combine(FixtureDirectory, name);

            if (updating)
            {
                File.WriteAllText(path, json + "\n");
                continue;
            }

            if (!File.Exists(path)) { drifted.Add($"{name}: missing"); continue; }

            var committed = File.ReadAllText(path).ReplaceLineEndings("\n").TrimEnd('\n');
            if (committed != json.ReplaceLineEndings("\n")) drifted.Add($"{name}: differs");
        }

        Assert.True(drifted.Count == 0,
            $"The wire format changed: {string.Join(", ", drifted)}.\n" +
            "The iOS side decodes these exact bytes (UnitTests/ContractTests.swift), so check both " +
            "Swift mirrors of the DTO still work, then regenerate with:\n" +
            "  OMBC_UPDATE_CONTRACT=1 dotnet test Tests/BookClubApi.Tests/BookClubApi.Tests.csproj");
    }

    [Fact]
    public void Dates_serialize_with_milliseconds_and_a_trailing_Z()
    {
        var json = JsonSerializer.Serialize(new { sentAt = SentAt }, Rest);

        // The iOS pagination cursor is formatted from this and compared with `<` on the server.
        // Losing the milliseconds would silently skip every message in the cursor's own second —
        // a bug that looks like "a few messages are missing sometimes".
        Assert.Contains("2026-09-04T15:30:45.123Z", json);
    }

    [Fact]
    public void Message_type_serializes_with_the_capitalisation_the_swift_enum_expects()
    {
        var json = JsonSerializer.Serialize(new { type = MessageType.Voice }, Rest);

        // MessageType's Swift raw values are capitalised ("Voice") to match the .NET enum names.
        // Adding a naming policy to JsonStringEnumConverter — an easy-looking cleanup — would emit
        // "voice" and every message would decode as .unknown on the client.
        Assert.Contains("\"Voice\"", json);
    }
}
