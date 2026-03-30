using BookClubApi.Models;
using Microsoft.Azure.NotificationHubs;

namespace BookClubApi.Services;

public class NotificationService(IConfiguration config)
{
    private readonly NotificationHubClient _hub = NotificationHubClient
        .CreateClientFromConnectionString(
            config["Azure:NotificationHubConnectionString"],
            config["Azure:NotificationHubName"]);

    public async Task SendNewMessageAsync(IEnumerable<string> deviceTokens, MessageDto message)
    {
        var senderName = message.SenderName;
        var body = message.Type == MessageType.Voice
            ? $"{senderName} sent a voice message"
            : message.Body?.Length > 50
                ? $"{senderName}: {message.Body[..50]}..."
                : $"{senderName}: {message.Body}";

        var payload = $$"""
            {
                "aps": {
                    "alert": {"title": "Book Club", "body": "{{body}}"},
                    "sound": "default",
                    "badge": 1
                },
                "clubId": "{{message.ClubId}}"
            }
            """;

        var tasks = deviceTokens.Select(token =>
            _hub.SendAppleNativeNotificationAsync(payload, [token]));

        await Task.WhenAll(tasks);
    }
}
