using BookClubApi.Data;
using BookClubApi.Models;
using Microsoft.EntityFrameworkCore;

namespace BookClubApi.Services;

// Unread = non-voice messages from others after the user's last-seen marker, plus
// voice messages from others not yet heard (independent of last-seen). Excludes the
// user's own messages, blocked senders, and deleted messages. Shared by the books
// list (per-book counts) and the push fan-out (total, for the app icon badge).
public static class UnreadCalculator
{
    public static async Task<Dictionary<Guid, int>> PerBookAsync(AppDbContext db, Guid userId, List<Guid> bookIds)
    {
        var result = new Dictionary<Guid, int>();
        if (bookIds.Count == 0) return result;

        var lastSeen = await db.ChatReads
            .Where(cr => cr.UserId == userId && bookIds.Contains(cr.BookId) && cr.LastSeenMessageId != null)
            .Join(db.Messages, cr => cr.LastSeenMessageId, m => m.Id, (cr, m) => new { cr.BookId, m.SentAt })
            .ToDictionaryAsync(x => x.BookId, x => x.SentAt);

        var blocked = (await db.BlockedUsers.Where(b => b.BlockerId == userId).Select(b => b.BlockedId).ToListAsync()).ToHashSet();
        var heard = (await db.MessageHeards.Where(h => h.UserId == userId).Select(h => h.MessageId).ToListAsync()).ToHashSet();

        foreach (var bookId in bookIds)
        {
            var seenAt = lastSeen.TryGetValue(bookId, out var s) ? s : DateTime.MinValue;
            var msgs = await db.Messages
                .Where(m => m.BookId == bookId && m.SenderId != userId && m.DeletedAt == null
                    && (m.Type == MessageType.Voice || m.SentAt > seenAt))
                .Select(m => new { m.Id, m.Type, m.SenderId })
                .ToListAsync();

            result[bookId] = msgs.Count(m =>
                !blocked.Contains(m.SenderId)
                && (m.Type != MessageType.Voice || !heard.Contains(m.Id)));
        }
        return result;
    }

    // Total unread across all the user's books — drives the app icon badge.
    public static async Task<int> TotalAsync(AppDbContext db, Guid userId)
    {
        var clubIds = await db.Memberships.Where(m => m.UserId == userId).Select(m => m.ClubId).ToListAsync();
        var bookIds = await db.Books.Where(b => clubIds.Contains(b.ClubId)).Select(b => b.Id).ToListAsync();
        var perBook = await PerBookAsync(db, userId, bookIds);
        return perBook.Values.Sum();
    }
}
