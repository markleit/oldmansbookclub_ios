using System.ComponentModel.DataAnnotations;

namespace BookClubApi.Models;

public record AppleAuthRequest(string IdentityToken, string DisplayName, string? Email = null, string? ClubName = null, Guid? JoinClubId = null, string? AuthorizationCode = null);
public record ClubDto(Guid Id, string Name, string? Description);
public record SetClubAdminRequest(bool IsClubAdmin);
public record ClubMembershipDto(Guid Id, string Name, string? Description, bool IsClubAdmin);
public record PublicClubDto(Guid Id, string Name, int MemberCount);
public record JoinRequestDto(Guid Id, Guid UserId, string DisplayName, string? Email, Guid ClubId, string ClubName, DateTime CreatedAt);
public record DevLoginRequest(string DisplayName);
public record DemoLoginRequest(string Passphrase);
public record AuthResponse(string AccessToken, string RefreshToken, UserDto User);
public record RefreshTokenRequest(string RefreshToken);

public record UserDto(Guid Id, string DisplayName, string? Nickname, string? AvatarUrl, bool IsAdmin, bool IsClubAdmin, UserPreferencesDto Preferences);
public record UserPreferencesDto(bool TapToTalk);

public record PendingUserDto(Guid Id, string DisplayName, string? Email, DateTime CreatedAt);
public record UpdateProfileRequest(
    [MaxLength(200)] string? DisplayName,
    [MaxLength(50)] string? Nickname,
    [MaxLength(2048)] string? AvatarUrl,
    UpdatePreferencesRequest? Preferences);
public record UpdatePreferencesRequest(bool? TapToTalk);

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
    DateTime SentAt,
    bool IsDeleted,
    bool IsForwarded,
    Guid? ClientId = null,
    Guid? ParentMessageId = null,
    string? ParentSenderName = null,
    string? ParentPreview = null,
    DateTime? ParentSentAt = null,
    string? Transcript = null,
    IReadOnlyList<MessageReactionDto>? Reactions = null
);

// Client-required ClientId (unlike the hub's optional overloads) — every client build that
// can reach the REST send endpoint already generates one per send for dedup/reconciliation.
public record SendMessageRequest(
    MessageType Type,
    string? Body,
    string? MediaUrl,
    int? DurationSeconds,
    Guid ClientId,
    Guid? ParentMessageId,
    string? DeviceId
);

// #47 — per-user reactions carried on each message; the client derives emoji counts + "mine"
// and applies live ReactionReceipts against this set. Names for the tap-to-see-who popup come
// from GET .../reactions (ReactionReactorDto) to keep the message payload light.
public record MessageReactionDto(Guid UserId, string Emoji);
public record SetReactionRequest(string Emoji);
public record ReactionReactorDto(Guid UserId, string DisplayName, string Emoji);

public record SavedMessageDto(
    Guid SavedId,
    Guid MessageId,
    string SenderName,
    MessageType Type,
    string? Body,
    string? MediaUrl,
    int? DurationSeconds,
    DateTime SentAt,
    DateTime SavedAt,
    bool IsDeleted
);

public record SendTextRequest(string Body);
public record SendVoiceRequest(string MediaUrl, int DurationSeconds);
public record UploadUrlResponse(string UploadUrl, string MediaUrl);
public record RegisterDeviceRequest(string DeviceToken);
public record SetRoleRequest(bool IsAdmin);
public record SeedMessagesRequest(string BookTitle, string Type, int Count = 1, string? SenderName = null);
public record BookDto(Guid Id, Guid ClubId, string Title, string Author, string? CoverBlobUrl, DateTime AddedAt, DateTime? FinishedAt, string Status, string? Description, int? PublishedYear, int? PageCount, int UnreadCount = 0, string? SeriesName = null, int? SeriesOrder = null);
public record CreateBookRequest(Guid ClubId, string Title, string Author, string? CoverUrl, string? SeriesName = null);
public record UpdateBookRequest(string Title, string Author, string? SeriesName = null);
public record SetBookStatusRequest(string Status);
public record SetFutureReadOrderRequest(Guid ClubId, List<Guid> OrderedBookIds);
public record SetTranscriptRequest(string Transcript);
public record ReportDto(Guid Id, Guid MessageId, string ReporterName, string SenderName, MessageType MessageType, string? MessageBody, DateTime SentAt, DateTime ReportedAt);
public record ChatReadDto(Guid UserId, string DisplayName, string? AvatarUrl, Guid LastSeenMessageId, List<Guid> HeardMessageIds);
public record CreateFeedbackRequest(string Title, string Body, string? AppVersion = null);
public record FeedbackDto(int Number, string Title, string State, string HtmlUrl, DateTime CreatedAt);

// #100 — client crash/hang diagnostic reported by MetricKit on the device, auto-filed as a
// deduped GitHub issue. Kind: "crash" | "hang" | "cpu" | "disk". Signature is a stable short
// hash of the call stack so recurrences fold into one issue.
public record DiagnosticReportRequest(
    string Kind, string Signature, string Summary,
    string? AppVersion = null, string? Build = null, string? OsVersion = null,
    string? DeviceModel = null, string? PayloadJson = null);
