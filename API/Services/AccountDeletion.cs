using BookClubApi.Data;
using Microsoft.EntityFrameworkCore;

namespace BookClubApi.Services;

// #244 — deletes a user and everything that's theirs, for "Delete my account" (AuthController) and
// the admin's "Delete user" (AdminController). One implementation, because the two copies had
// drifted: the self-service one failed for every user (a bare transaction under
// EnableRetryOnFailure, #153's bug, fixed only in the admin copy), and both failed for anyone who
// had opened a chat, played a voice message, reacted, or been replied to — rows whose foreign keys
// are NoAction and which neither copy removed (#133). Apple requires working in-app deletion.
//
// What goes: the user, their messages, and every row that's theirs (memberships, devices, sign-ins,
// read markers, heard and reaction marks, saved messages, reports, blocks, join requests,
// reserved videos). What stays, adjusted, for everyone else:
// - a reply quoting one of their messages keeps its text and loses the quote (its original is gone);
// - a read marker resting on one of their messages moves back to the last message before it, so
//   nobody's chat suddenly counts as all unread (UnreadCalculator joins the marker to its message).
public static class AccountDeletion
{
    public static async Task DeleteAsync(AppDbContext db, Guid userId)
    {
        // All-or-nothing, inside the execution strategy: EnableRetryOnFailure refuses a transaction
        // it didn't start itself (#153).
        var strategy = db.Database.CreateExecutionStrategy();
        await strategy.ExecuteAsync(async () =>
        {
            await using var transaction = await db.Database.BeginTransactionAsync();
            var theirs = db.Messages.Where(m => m.SenderId == userId).Select(m => m.Id);

            await db.Messages
                .Where(m => m.ParentMessageId != null && theirs.Contains(m.ParentMessageId.Value))
                .ExecuteUpdateAsync(s => s.SetProperty(m => m.ParentMessageId, (Guid?)null));

            await MoveReadMarkersOffAsync(db, userId);

            await db.Reports.Where(r => r.ReporterId == userId || theirs.Contains(r.MessageId)).ExecuteDeleteAsync();
            await db.SavedMessages.Where(s => s.UserId == userId || theirs.Contains(s.MessageId)).ExecuteDeleteAsync();
            await db.MessageHeards.Where(h => h.UserId == userId || theirs.Contains(h.MessageId)).ExecuteDeleteAsync();
            await db.MessageReactions.Where(r => r.UserId == userId || theirs.Contains(r.MessageId)).ExecuteDeleteAsync();
            await db.ChatReads.Where(c => c.UserId == userId).ExecuteDeleteAsync();
            await db.Messages.Where(m => m.SenderId == userId).ExecuteDeleteAsync();
            await db.JoinRequests.Where(jr => jr.UserId == userId).ExecuteDeleteAsync();
            await db.BlockedUsers.Where(b => b.BlockerId == userId || b.BlockedId == userId).ExecuteDeleteAsync();
            await db.Memberships.Where(m => m.UserId == userId).ExecuteDeleteAsync();
            // Devices, refresh tokens (and with them the send token) and reserved videos cascade.
            await db.Users.Where(u => u.Id == userId).ExecuteDeleteAsync();

            await transaction.CommitAsync();
        });
    }

    // Others' read markers resting on this user's messages: back to the newest earlier message of
    // someone else's in that chat — what they'd seen up to, minus what's being deleted. None
    // earlier means nothing before it is left to have read, and no marker says exactly that.
    private static async Task MoveReadMarkersOffAsync(AppDbContext db, Guid userId)
    {
        var markers = await db.ChatReads
            .Where(c => c.UserId != userId && c.LastSeenMessageId != null)
            .Join(db.Messages.Where(m => m.SenderId == userId), c => c.LastSeenMessageId, m => m.Id,
                (c, m) => new { c.UserId, c.BookId, m.ReceivedAt })
            .ToListAsync();
        foreach (var marker in markers)
        {
            var earlier = await db.Messages
                .Where(m => m.BookId == marker.BookId && m.SenderId != userId && m.ReceivedAt <= marker.ReceivedAt)
                .OrderByDescending(m => m.ReceivedAt).ThenByDescending(m => m.Id)
                .Select(m => (Guid?)m.Id)
                .FirstOrDefaultAsync();
            await db.ChatReads
                .Where(c => c.UserId == marker.UserId && c.BookId == marker.BookId)
                .ExecuteUpdateAsync(s => s.SetProperty(c => c.LastSeenMessageId, earlier));
        }
    }
}
