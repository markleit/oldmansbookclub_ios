using System.ComponentModel.DataAnnotations;

namespace BookClubApi.Models;

public class User
{
    public Guid Id { get; set; } = Guid.NewGuid();
    [Required] public string AppleSubject { get; set; } = "";
    [Required] public string DisplayName { get; set; } = "";
    public string? DeviceToken { get; set; }
    public DateTime CreatedAt { get; set; } = DateTime.UtcNow;
    public ICollection<Membership> Memberships { get; set; } = [];
}

public class Club
{
    public Guid Id { get; set; } = Guid.NewGuid();
    [Required] public string Name { get; set; } = "";
    public string? Description { get; set; }
    public string? CoverBlobUrl { get; set; }
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
    public string? Body { get; set; }
    public string? MediaUrl { get; set; }
    public int? DurationSeconds { get; set; }
    public DateTime SentAt { get; set; } = DateTime.UtcNow;
    public DateTime? DeletedAt { get; set; }
}

public enum MessageType { Text, Voice, Photo }

public class Book
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public Guid ClubId { get; set; }
    public Club Club { get; set; } = null!;
    [Required] public string Title { get; set; } = "";
    [Required] public string Author { get; set; } = "";
    public string? CoverBlobUrl { get; set; }
    public DateTime AddedAt { get; set; } = DateTime.UtcNow;
    public DateTime? FinishedAt { get; set; }
    [Required] public string Status { get; set; } = "future"; // "future", "current", "past"
    public ICollection<Message> Messages { get; set; } = [];
}
