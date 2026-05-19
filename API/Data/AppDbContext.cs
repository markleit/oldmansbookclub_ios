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

    protected override void OnModelCreating(ModelBuilder modelBuilder)
    {
        modelBuilder.Entity<Membership>()
            .HasIndex(m => new { m.UserId, m.ClubId })
            .IsUnique();

        modelBuilder.Entity<Message>()
            .HasIndex(m => new { m.ClubId, m.SentAt });

        modelBuilder.Entity<Message>()
            .HasOne(m => m.Book)
            .WithMany(b => b.Messages)
            .HasForeignKey(m => m.BookId)
            .OnDelete(DeleteBehavior.NoAction);

        modelBuilder.Entity<User>()
            .HasIndex(u => u.AppleSubject)
            .IsUnique();

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
    }
}
