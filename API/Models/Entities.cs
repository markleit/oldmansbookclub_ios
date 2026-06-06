using System.ComponentModel.DataAnnotations;

namespace BookClubApi.Models;

public class User
{
    public Guid Id { get; set; } = Guid.NewGuid();
    [Required, MaxLength(255)] public string AppleSubject { get; set; } = "";
    [Required, MaxLength(200)] public string DisplayName { get; set; } = "";
    [MaxLength(50)] public string? Nickname { get; set; }
    [MaxLength(2048)] public string? AvatarUrl { get; set; }
    // Updated whenever AvatarUrl is set/changed. Used to bust client-side image
    // caches that key blob URLs by path (since avatar blobs reuse a fixed path
    // per user, the path alone doesn't change when the avatar is replaced).
    public DateTime? AvatarUpdatedAt { get; set; }
    [MaxLength(512)] public string? DeviceToken { get; set; }
    [MaxLength(255)] public string? Email { get; set; }
    [MaxLength(2048)] public string? AppleRefreshToken { get; set; }
    public bool IsApproved { get; set; } = false;
    public bool IsAdmin { get; set; } = false;
    public UserPreferences Preferences { get; set; } = new();
    public DateTime CreatedAt { get; set; } = DateTime.UtcNow;
    public ICollection<Membership> Memberships { get; set; } = [];

    public string EffectiveName => Nickname ?? DisplayName;
}

// Stored as a JSON column — add new settings here, no migration needed
public class UserPreferences
{
    public bool TapToTalk { get; set; } = false;
}

public class Club
{
    public Guid Id { get; set; } = Guid.NewGuid();
    [Required, MaxLength(200)] public string Name { get; set; } = "";
    [MaxLength(1000)] public string? Description { get; set; }
    [MaxLength(2048)] public string? CoverBlobUrl { get; set; }
    public DateTime CreatedAt { get; set; } = DateTime.UtcNow;
    public ICollection<Membership> Memberships { get; set; } = [];
    public ICollection<Message> Messages { get; set; } = [];
}

public class Membership
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public Guid UserId { get; set; }
    public User User { get; set; } = null!;
    public Guid ClubId { get; set; }
    public Club Club { get; set; } = null!;
    public bool IsClubAdmin { get; set; } = false;
    public DateTime JoinedAt { get; set; } = DateTime.UtcNow;
}

public class Message
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public Guid ClubId { get; set; }
    public Club Club { get; set; } = null!;
    public Guid? BookId { get; set; }
    public Book? Book { get; set; }
    public Guid SenderId { get; set; }
    public User Sender { get; set; } = null!;
    public MessageType Type { get; set; }
    [MaxLength(4000)] public string? Body { get; set; }
    [MaxLength(2048)] public string? MediaUrl { get; set; }
    public int? DurationSeconds { get; set; }
    public DateTime SentAt { get; set; } = DateTime.UtcNow;
    public DateTime? DeletedAt { get; set; }
    public bool IsForwarded { get; set; } = false;
    public Guid? ClientId { get; set; }
}

public enum MessageType { Text, Voice, Photo, Video }

public class SavedMessage
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public Guid UserId { get; set; }
    public User User { get; set; } = null!;
    public Guid MessageId { get; set; }
    public Message Message { get; set; } = null!;
    public DateTime SavedAt { get; set; } = DateTime.UtcNow;
}

public class Report
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public Guid ReporterId { get; set; }
    public User Reporter { get; set; } = null!;
    public Guid MessageId { get; set; }
    public Message Message { get; set; } = null!;
    public DateTime CreatedAt { get; set; } = DateTime.UtcNow;
}

public class BlockedUser
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public Guid BlockerId { get; set; }
    public User Blocker { get; set; } = null!;
    public Guid BlockedId { get; set; }
    public User Blocked { get; set; } = null!;
    public DateTime CreatedAt { get; set; } = DateTime.UtcNow;
}

public enum JoinRequestStatus { Pending, Approved, Declined }

public class JoinRequest
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public Guid UserId { get; set; }
    public User User { get; set; } = null!;
    public Guid ClubId { get; set; }
    public Club Club { get; set; } = null!;
    public JoinRequestStatus Status { get; set; } = JoinRequestStatus.Pending;
    public DateTime CreatedAt { get; set; } = DateTime.UtcNow;
}

public class ChatRead
{
    public Guid UserId { get; set; }
    public User User { get; set; } = null!;
    public Guid BookId { get; set; }
    public Book Book { get; set; } = null!;
    public Guid? LastSeenMessageId { get; set; }
    public DateTime UpdatedAt { get; set; } = DateTime.UtcNow;
}

public class RefreshToken
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public Guid UserId { get; set; }
    public User User { get; set; } = null!;
    // SHA-256 of the opaque token returned to the client. We never store the raw token
    // so a DB compromise doesn't yield live sessions.
    [Required, MaxLength(64)] public string TokenHash { get; set; } = "";
    public DateTime ExpiresAt { get; set; }
    public DateTime CreatedAt { get; set; } = DateTime.UtcNow;
    public DateTime? RevokedAt { get; set; }
}

public class Book
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public Guid ClubId { get; set; }
    public Club Club { get; set; } = null!;
    [Required, MaxLength(500)] public string Title { get; set; } = "";
    [Required, MaxLength(300)] public string Author { get; set; } = "";
    [MaxLength(2048)] public string? CoverBlobUrl { get; set; }
    public DateTime AddedAt { get; set; } = DateTime.UtcNow;
    public DateTime? FinishedAt { get; set; }
    [Required] public string Status { get; set; } = "future"; // "future", "current", "past"
    public ICollection<Message> Messages { get; set; } = [];
}
