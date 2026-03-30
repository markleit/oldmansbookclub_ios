using BookClubApi.Data;
using BookClubApi.Models;
using BookClubApi.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.SignalR;
using Microsoft.EntityFrameworkCore;

namespace BookClubApi.Hubs;

[Authorize]
public class ChatHub(AppDbContext db, NotificationService notifications) : Hub
{
    public async Task JoinClub(Guid clubId)
    {
        var userId = GetUserId();
        var isMember = await db.Memberships
            .AnyAsync(m => m.UserId == userId && m.ClubId == clubId);

        if (isMember)
            await Groups.AddToGroupAsync(Context.ConnectionId, clubId.ToString());
    }

    public async Task SendTextMessage(Guid clubId, string body)
    {
        var message = await SaveMessageAsync(clubId, MessageType.Text, body: body);
        await BroadcastAndNotify(clubId, message);
    }

    public async Task SendVoiceMessage(Guid clubId, string mediaUrl, int durationSeconds)
    {
        var message = await SaveMessageAsync(clubId, MessageType.Voice,
            mediaUrl: mediaUrl, durationSeconds: durationSeconds);
        await BroadcastAndNotify(clubId, message);
    }

    private async Task<MessageDto> SaveMessageAsync(Guid clubId, MessageType type,
        string? body = null, string? mediaUrl = null, int? durationSeconds = null)
    {
        var userId = GetUserId();
        var user = await db.Users.FindAsync(userId)
            ?? throw new HubException("User not found");

        var message = new Message
        {
            ClubId = clubId,
            SenderId = userId,
            Type = type,
            Body = body,
            MediaUrl = mediaUrl,
            DurationSeconds = durationSeconds
        };

        db.Messages.Add(message);
        await db.SaveChangesAsync();

        return ToDto(message, user.DisplayName);
    }

    private async Task BroadcastAndNotify(Guid clubId, MessageDto dto)
    {
        await Clients.Group(clubId.ToString()).SendAsync("NewMessage", dto);

        var offlineTokens = await db.Memberships
            .Where(m => m.ClubId == clubId && m.UserId != dto.SenderId)
            .Select(m => m.User.DeviceToken)
            .Where(t => t != null)
            .Cast<string>()
            .ToListAsync();

        if (offlineTokens.Count > 0)
            await notifications.SendNewMessageAsync(offlineTokens, dto);
    }

    private Guid GetUserId() =>
        Guid.Parse(Context.UserIdentifier
            ?? throw new HubException("Unauthorized"));

    private static MessageDto ToDto(Message m, string senderName) => new(
        m.Id, m.ClubId, m.SenderId, senderName,
        m.Type, m.Body, m.MediaUrl, m.DurationSeconds, m.SentAt);
}
