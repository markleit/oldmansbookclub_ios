using BookClubApi.Models;
using Microsoft.EntityFrameworkCore;

namespace BookClubApi.Data;

public class AppDbContext(DbContextOptions<AppDbContext> options) : DbContext(options)
{
    public DbSet<User> Users => Set<User>();
    public DbSet<Club> Clubs => Set<Club>();
    public DbSet<Membership> Memberships => Set<Membership>();
    public DbSet<Message> Messages => Set<Message>();
    public DbSet<Book> Books => Set<Book>();
    public DbSet<SavedMessage> SavedMessages => Set<SavedMessage>();
    public DbSet<Report> Reports => Set<Report>();
    public DbSet<BlockedUser> BlockedUsers => Set<BlockedUser>();
    public DbSet<JoinRequest> JoinRequests => Set<JoinRequest>();
    public DbSet<ChatRead> ChatReads => Set<ChatRead>();
    public DbSet<MessageHeard> MessageHeards => Set<MessageHeard>();
    public DbSet<RefreshToken> RefreshTokens => Set<RefreshToken>();

    protected override void OnModelCreating(ModelBuilder modelBuilder)
    {
        modelBuilder.Entity<Membership>()
            .HasIndex(m => new { m.UserId, m.ClubId })
            .IsUnique();

        modelBuilder.Entity<Message>()
            .HasIndex(m => new { m.ClubId, m.SentAt });

        modelBuilder.Entity<Message>()
            .HasIndex(m => new { m.BookId, m.SentAt });

        modelBuilder.Entity<Message>()
            .HasIndex(m => m.ClientId)
            .HasFilter("[ClientId] IS NOT NULL");

        // Self-reference for inline quoted replies. NoAction: parents are soft-deleted,
        // never hard-deleted, so no cascade is needed (and it avoids a cascade cycle).
        modelBuilder.Entity<Message>()
            .HasOne(m => m.Parent)
            .WithMany()
            .HasForeignKey(m => m.ParentMessageId)
            .OnDelete(DeleteBehavior.NoAction);

        modelBuilder.Entity<Message>()
            .HasOne(m => m.Book)
            .WithMany(b => b.Messages)
            .HasForeignKey(m => m.BookId)
            .OnDelete(DeleteBehavior.NoAction);

        modelBuilder.Entity<User>()
            .HasIndex(u => u.AppleSubject)
            .IsUnique();

        modelBuilder.Entity<User>()
            .OwnsOne(u => u.Preferences, b => b.ToJson());

        modelBuilder.Entity<SavedMessage>()
            .HasIndex(s => new { s.UserId, s.MessageId })
            .IsUnique();

        modelBuilder.Entity<SavedMessage>()
            .HasOne(s => s.Message)
            .WithMany()
            .HasForeignKey(s => s.MessageId)
            .OnDelete(DeleteBehavior.Cascade);

        modelBuilder.Entity<SavedMessage>()
            .HasOne(s => s.User)
            .WithMany()
            .HasForeignKey(s => s.UserId)
            .OnDelete(DeleteBehavior.NoAction);

        modelBuilder.Entity<Report>()
            .HasOne(r => r.Reporter)
            .WithMany()
            .HasForeignKey(r => r.ReporterId)
            .OnDelete(DeleteBehavior.NoAction);

        modelBuilder.Entity<Report>()
            .HasOne(r => r.Message)
            .WithMany()
            .HasForeignKey(r => r.MessageId)
            .OnDelete(DeleteBehavior.NoAction);

        modelBuilder.Entity<BlockedUser>()
            .HasIndex(b => new { b.BlockerId, b.BlockedId })
            .IsUnique();

        modelBuilder.Entity<BlockedUser>()
            .HasOne(b => b.Blocker)
            .WithMany()
            .HasForeignKey(b => b.BlockerId)
            .OnDelete(DeleteBehavior.NoAction);

        modelBuilder.Entity<BlockedUser>()
            .HasOne(b => b.Blocked)
            .WithMany()
            .HasForeignKey(b => b.BlockedId)
            .OnDelete(DeleteBehavior.NoAction);

        modelBuilder.Entity<JoinRequest>()
            .HasIndex(jr => new { jr.UserId, jr.ClubId })
            .IsUnique();

        modelBuilder.Entity<JoinRequest>()
            .HasOne(jr => jr.User)
            .WithMany()
            .HasForeignKey(jr => jr.UserId)
            .OnDelete(DeleteBehavior.NoAction);

        modelBuilder.Entity<JoinRequest>()
            .HasOne(jr => jr.Club)
            .WithMany()
            .HasForeignKey(jr => jr.ClubId)
            .OnDelete(DeleteBehavior.Cascade);

        modelBuilder.Entity<ChatRead>()
            .HasKey(cr => new { cr.UserId, cr.BookId });

        modelBuilder.Entity<ChatRead>()
            .HasOne(cr => cr.User)
            .WithMany()
            .HasForeignKey(cr => cr.UserId)
            .OnDelete(DeleteBehavior.NoAction);

        modelBuilder.Entity<ChatRead>()
            .HasOne(cr => cr.Book)
            .WithMany()
            .HasForeignKey(cr => cr.BookId)
            .OnDelete(DeleteBehavior.Cascade);

        modelBuilder.Entity<MessageHeard>()
            .HasKey(h => new { h.UserId, h.MessageId });

        modelBuilder.Entity<MessageHeard>()
            .HasOne(h => h.User)
            .WithMany()
            .HasForeignKey(h => h.UserId)
            .OnDelete(DeleteBehavior.NoAction);

        modelBuilder.Entity<MessageHeard>()
            .HasOne(h => h.Message)
            .WithMany()
            .HasForeignKey(h => h.MessageId)
            .OnDelete(DeleteBehavior.Cascade);

        modelBuilder.Entity<RefreshToken>()
            .HasIndex(rt => rt.TokenHash)
            .IsUnique();

        modelBuilder.Entity<RefreshToken>()
            .HasIndex(rt => rt.UserId);

        modelBuilder.Entity<RefreshToken>()
            .HasOne(rt => rt.User)
            .WithMany()
            .HasForeignKey(rt => rt.UserId)
            .OnDelete(DeleteBehavior.Cascade);
    }
}
