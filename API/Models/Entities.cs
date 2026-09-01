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
    // #36 natural-PK cleanup deferred: dropping this artificial Id isn't backward-compatible
    // with a still-running old server during deploy, and it has no functional value — do it
    // later as its own coordinated change if ever.
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
    public Guid BookId { get; set; }   // #36 — always set in practice; now non-nullable
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
    // Inline quoted reply: the message this one is replying to (null = not a reply).
    public Guid? ParentMessageId { get; set; }
    public Message? Parent { get; set; }
    // On-device transcript of a voice message, uploaded by whoever transcribed it, so a
    // reply quoting this message can show its first words to everyone (not just devices
    // that ran transcription locally).
    [MaxLength(4000)] public string? Transcript { get; set; }
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

// A voice message a user has heard (fully played or "marked as heard"). Sticky:
// once recorded it's never removed by replays. Drives voice read receipts, the
// unread counter, and the app badge.
public class MessageHeard
{
    public Guid UserId { get; set; }
    public User User { get; set; } = null!;
    public Guid MessageId { get; set; }
    public Message Message { get; set; } = null!;
    public DateTime HeardAt { get; set; } = DateTime.UtcNow;
}

// #47 — one emoji reaction per user per message (composite PK). Switching emoji updates the
// Emoji on the existing row; removing deletes it.
public class MessageReaction
{
    public Guid UserId { get; set; }
    public User User { get; set; } = null!;
    public Guid MessageId { get; set; }
    public Message Message { get; set; } = null!;
    public string Emoji { get; set; } = "";
    public DateTime ReactedAt { get; set; } = DateTime.UtcNow;
}

// #25 — one row per physical device, replacing the old single User.DeviceToken column so a
// user's push reaches every device they're signed into, not just whichever registered last.
// DeviceToken is globally unique: registering re-points ("claims") the row to the current
// user if the token previously belonged to someone else (e.g. dev-login/demo/test accounts
// sharing one physical device).
public class UserDevice
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public Guid UserId { get; set; }
    public User User { get; set; } = null!;
    [Required, MaxLength(512)] public string DeviceToken { get; set; } = "";
    public DateTime CreatedAt { get; set; } = DateTime.UtcNow;
    public DateTime LastSeenAt { get; set; } = DateTime.UtcNow;
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
    // Metadata from Google Books, populated lazily on first Details view (null = not
    // yet fetched). MetadataFetchedAt prevents re-fetching when a book genuinely has
    // no description/pages on Google.
    [MaxLength(4000)] public string? Description { get; set; }
    public int? PublishedYear { get; set; }
    public int? PageCount { get; set; }
    public DateTime? MetadataFetchedAt { get; set; }
    public DateTime AddedAt { get; set; } = DateTime.UtcNow;
    public DateTime? FinishedAt { get; set; }
    [Required] public string Status { get; set; } = "future"; // "future", "current", "past"
    // #137 — manual queue order within "future" for this book's club. Only meaningful while
    // Status == "future"; ignored (and left stale) once a book moves to current/past. Lower
    // sorts first ("read sooner"). New books are appended (max + 1), not reset to 0, so adding
    // a book never silently jumps it ahead of an admin's existing order.
    public int FutureReadOrder { get; set; }
    // #138 — free-text series grouping (mirrors Author: a plain string, not a Series entity —
    // see the issue for why). Null = not in a series. SeriesOrder is this book's position
    // within the series (1st, 2nd, ...) and is meaningless when SeriesName is null. Persists
    // across future/current/past — series membership is a property of the book, not of where
    // it sits in the library.
    [MaxLength(200)] public string? SeriesName { get; set; }
    public int? SeriesOrder { get; set; }
    public ICollection<Message> Messages { get; set; } = [];
}
