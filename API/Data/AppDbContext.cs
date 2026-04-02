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

    protected override void OnModelCreating(ModelBuilder modelBuilder)
    {
        modelBuilder.Entity<Membership>()
            .HasIndex(m => new { m.UserId, m.ClubId })
            .IsUnique();

        modelBuilder.Entity<Message>()
            .HasIndex(m => new { m.ClubId, m.SentAt });

        modelBuilder.Entity<User>()
            .HasIndex(u => u.AppleSubject)
            .IsUnique();
    }
}
