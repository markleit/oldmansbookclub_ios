using BookClubApi.Data;
using BookClubApi.Models;
using Microsoft.EntityFrameworkCore;

namespace BookClubApi.Services;

// Unread = non-voice messages from others that ARRIVED after the user's last-seen marker
// arrived (#204: by ReceivedAt, not SentAt — a message held up by an outage carries its earlier
// SentAt, and comparing that would count it as already read), plus
// voice messages from others not yet heard (independent of last-seen). Excludes the
// user's own messages, blocked senders, and deleted messages. Shared by the books
// list (per-book counts), the push fan-out (total, for the app icon badge) and the chat's
// unread list (#275).
public static class UnreadCalculator
{
    public static async Task<Dictionary<Guid, int>> PerBookAsync(AppDbContext db, Guid userId, List<Guid> bookIds)
    {
        var result = new Dictionary<Guid, int>();
        if (bookIds.Count == 0) return result;

        var lastSeen = await db.ChatReads
            .Where(cr => cr.UserId == userId && bookIds.Contains(cr.BookId) && cr.LastSeenMessageId != null)
            .Join(db.Messages, cr => cr.LastSeenMessageId, m => m.Id, (cr, m) => new { cr.BookId, m.ReceivedAt })
            .ToDictionaryAsync(x => x.BookId, x => x.ReceivedAt);

        var blocked = (await db.BlockedUsers.Where(b => b.BlockerId == userId).Select(b => b.BlockedId).ToListAsync()).ToHashSet();
        var heard = (await db.MessageHeards.Where(h => h.UserId == userId).Select(h => h.MessageId).ToListAsync()).ToHashSet();

        foreach (var bookId in bookIds)
        {
            var seenAt = lastSeen.TryGetValue(bookId, out var s) ? s : DateTime.MinValue;
            result[bookId] = (await UnreadRowsAsync(db, userId, bookId, seenAt, blocked, heard)).Count;
        }
        return result;
    }

    // The unread messages themselves for one book, newest first (#275). Same rule as the count,
    // through the same code, so the chat's "↑ N unread" can never disagree with the library number.
    public static async Task<List<UnreadMessageRef>> InBookAsync(AppDbContext db, Guid userId, Guid bookId)
    {
        var seenAt = await db.ChatReads
            .Where(cr => cr.UserId == userId && cr.BookId == bookId && cr.LastSeenMessageId != null)
            .Join(db.Messages, cr => cr.LastSeenMessageId, m => m.Id, (cr, m) => (DateTime?)m.ReceivedAt)
            .FirstOrDefaultAsync() ?? DateTime.MinValue;
        var blocked = (await db.BlockedUsers.Where(b => b.BlockerId == userId).Select(b => b.BlockedId).ToListAsync()).ToHashSet();
        var heard = (await db.MessageHeards
            .Where(h => h.UserId == userId && h.Message.BookId == bookId)
            .Select(h => h.MessageId).ToListAsync()).ToHashSet();
        return await UnreadRowsAsync(db, userId, bookId, seenAt, blocked, heard);
    }

    private static async Task<List<UnreadMessageRef>> UnreadRowsAsync(AppDbContext db, Guid userId, Guid bookId,
        DateTime seenAt, HashSet<Guid> blocked, HashSet<Guid> heard)
    {
        var msgs = await db.Messages
            .Where(m => m.BookId == bookId && m.SenderId != userId && m.DeletedAt == null
                && (m.Type == MessageType.Voice || m.ReceivedAt > seenAt))
            .OrderByDescending(m => m.SentAt).ThenByDescending(m => m.Id)
            .Select(m => new { m.Id, m.Type, m.SenderId, m.SentAt })
            .ToListAsync();

        return msgs
            .Where(m => !blocked.Contains(m.SenderId)
                && (m.Type != MessageType.Voice || !heard.Contains(m.Id)))
            .Select(m => new UnreadMessageRef(m.Id, m.SentAt))
            .ToList();
    }

    // Total unread across all the user's books — drives the app icon badge.
    public static async Task<int> TotalAsync(AppDbContext db, Guid userId)
        => (await TotalWithPerBookAsync(db, userId)).Total;

    // Both halves from one pass. The push fan-out needs the total (badge) and the pushed book's
    // own count (so the client can set that book exactly instead of guessing +1), and computing
    // the total already walks every book — so handing back the per-book dictionary is free.
    public static async Task<(int Total, Dictionary<Guid, int> PerBook)> TotalWithPerBookAsync(
        AppDbContext db, Guid userId)
    {
        var clubIds = await db.Memberships.Where(m => m.UserId == userId).Select(m => m.ClubId).ToListAsync();
        var bookIds = await db.Books.Where(b => clubIds.Contains(b.ClubId)).Select(b => b.Id).ToListAsync();
        var perBook = await PerBookAsync(db, userId, bookIds);
        return (perBook.Values.Sum(), perBook);
    }
}
