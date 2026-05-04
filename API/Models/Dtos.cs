namespace BookClubApi.Models;

public record AppleAuthRequest(string IdentityToken, string DisplayName);
public record DevLoginRequest(string DisplayName);
public record AuthResponse(string AccessToken, UserDto User);

public record UserDto(Guid Id, string DisplayName);

public record MessageDto(
    Guid Id,
    Guid ClubId,
    Guid SenderId,
    string SenderName,
    MessageType Type,
    string? Body,
    string? MediaUrl,
    int? DurationSeconds,
    DateTime SentAt
);

public record SendTextRequest(string Body);
public record SendVoiceRequest(string MediaUrl, int DurationSeconds);
public record UploadUrlResponse(string UploadUrl, string MediaUrl);
public record RegisterDeviceRequest(string DeviceToken);
public record BookDto(Guid Id, Guid ClubId, string Title, string Author, string? CoverBlobUrl, DateTime AddedAt, DateTime? FinishedAt, string Status);
public record CreateBookRequest(Guid ClubId, string Title, string Author, string? CoverUrl);
public record SetBookStatusRequest(string Status);
