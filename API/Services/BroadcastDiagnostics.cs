namespace BookClubApi.Services;

// TEMP debug — exposes the last URL we handed to Clients.Group.SendAsync so we
// can curl it directly when App Service log capture is too laggy to be useful.
public static class BroadcastDiagnostics
{
    public static string? LastBroadcastMediaUrl;
    public static DateTime? LastBroadcastAt;
    public static int BroadcastCount;
    public static int SendPhotoMessageEntryCount;
    public static string? LastSendPhotoError;
    public static DateTime ProcessStart = DateTime.UtcNow;
}
