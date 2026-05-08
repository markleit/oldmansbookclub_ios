using System.ComponentModel.DataAnnotations;

namespace BookClubApi.Models;

public record AppleAuthRequest(string IdentityToken, string DisplayName, string? Email = null);
public record DevLoginRequest(string DisplayName);
public record AuthResponse(string AccessToken, UserDto User);

public record UserDto(Guid Id, string DisplayName, string? Nickname, string? AvatarUrl, bool IsAdmin);
public record PendingUserDto(Guid Id, string DisplayName, string? Email, DateTime CreatedAt);
public record UpdateProfileRequest(
    [MaxLength(200)] string? DisplayName,
    [MaxLength(50)] string? Nickname,
    [MaxLength(2048)] string? AvatarUrl);

public record CreateClubRequest(
    [Required, MaxLength(200)] string Name,
    [MaxLength(1000)] string? Description);

public record BookSearchResult(string Title, string Author, string? CoverUrl);

public record MessageDto(
    Guid Id,
    Guid ClubId,
    Guid SenderId,
    string SenderName,
    string? SenderAvatarUrl,
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
