import Foundation

/// The decision half of "a confirmed message has arrived — what happens to the list?".
///
/// Extracted from `BookViewModel.reconcileConfirmedMessage` so it can be tested without a view
/// model, a network stack, or the ten singletons that method reaches into. The rules it encodes
/// are the ones behind #35 (identical consecutive sends racing), #131 (background-session send
/// confirmation) and #146 (durable text outbox), and every one of them is invisible to the
/// compiler.
///
/// Deliberately returns a decision rather than performing it: prefetching audio, clearing the
/// send queue, deleting a local file and posting a read receipt are side effects with real
/// dependencies. Keeping them at the call site is what lets the rules themselves be plain data.
///
/// `ChatCache.merge` is the other implementation of this same idea, for the load path rather than
/// the live path. The two are tested against a shared table of cases (SendReconcilerTests) —
/// they have never agreed by construction, only by inspection.
enum SendReconciler {

    enum Outcome: Equatable {
        /// Belongs to a different club — this view model must not touch it.
        case ignoreWrongClub
        /// The other transport (SignalR echo vs. REST response) already delivered this one.
        case ignoreAlreadyApplied
        /// Our own optimistic bubble at `index` is this message; replace it in place.
        /// `previousMediaUrl` is the bubble's local file URL, if it had one, so the caller can
        /// clean it up.
        case replaceOptimistic(index: Int, clientId: UUID, previousMediaUrl: String?)
        /// Somebody else's message, or our own from another device — a new arrival.
        case insert
    }

    static func outcome(
        for message: Message,
        in messages: [Message],
        myUserId: UUID?,
        bookClubId: UUID
    ) -> Outcome {
        guard message.clubId == bookClubId else { return .ignoreWrongClub }

        // Checked BEFORE the clientId match: both transports can deliver the same confirmation,
        // and whichever arrives second must be a no-op rather than a second bubble.
        guard !messages.contains(where: { $0.id == message.id }) else { return .ignoreAlreadyApplied }

        // Match by clientId, never by body — two identical consecutive sends are
        // indistinguishable by content, which is exactly how #35 produced duplicates.
        if let myUserId, message.senderId == myUserId,
           let clientId = message.clientId,
           let index = messages.firstIndex(where: { $0.id == clientId }) {
            return .replaceOptimistic(index: index, clientId: clientId, previousMediaUrl: messages[index].mediaUrl)
        }

        return .insert
    }
}
