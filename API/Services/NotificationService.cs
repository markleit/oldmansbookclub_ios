using System.Text.Json;
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
        var alertBody = message.Type == MessageType.Voice
            ? $"{message.SenderName} sent a voice message"
            : message.Body?.Length > 50
                ? $"{message.SenderName}: {message.Body[..50]}..."
                : $"{message.SenderName}: {message.Body}";

        var payload = JsonSerializer.Serialize(new
        {
            aps = new
            {
                alert = new { title = "Book Club", body = alertBody },
                sound = "default",
                badge = 1
            },
            clubId = message.ClubId.ToString()
        });

        var tasks = deviceTokens.Select(token =>
            _hub.SendAppleNativeNotificationAsync(payload, [token]));

        await Task.WhenAll(tasks);
    }
}
