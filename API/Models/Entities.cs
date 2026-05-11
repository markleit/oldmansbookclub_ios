using System.ComponentModel.DataAnnotations;

namespace BookClubApi.Models;

public class User
{
    public Guid Id { get; set; } = Guid.NewGuid();
    [Required, MaxLength(255)] public string AppleSubject { get; set; } = "";
    [Required, MaxLength(200)] public string DisplayName { get; set; } = "";
    [MaxLength(50)] public string? Nickname { get; set; }
    [MaxLength(2048)] public string? AvatarUrl { get; set; }
    [MaxLength(512)] public string? DeviceToken { get; set; }
    [MaxLength(255)] public string? Email { get; set; }
    public bool IsApproved { get; set; } = false;
    public bool IsAdmin { get; set; } = false;
    public DateTime CreatedAt { get; set; } = DateTime.UtcNow;
    public ICollection<Membership> Memberships { get; set; } = [];

    public string EffectiveName => Nickname ?? DisplayName;
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
}

public enum MessageType { Text, Voice, Photo }

public class SavedMessage
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public Guid UserId { get; set; }
    public User User { get; set; } = null!;
    public Guid MessageId { get; set; }
    public Message Message { get; set; } = null!;
    public DateTime SavedAt { get; set; } = DateTime.UtcNow;
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
