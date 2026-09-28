import Foundation

// Per-chat send ordering. The server stamps SentAt when a message's POST arrives, and chats are
// ordered by it — so without this, send order and receive order diverge: media is posted only
// after its (parallel, background) upload finishes, text is posted immediately, and whichever
// POST lands first wins. A small photo sent after a video overtook it; text typed right after a
// photo landed above it.
//
// The fix is client-side head-of-line posting: every queued send (text and media) gets a
// sequence number when the user taps Send, uploads still run in parallel, but within a chat a
// message is POSTed only once everything queued before it has been posted. The decision is a
// pure function so it can be unit-tested; BookViewModel applies it (pumpSendQueue).
enum SendOrder {
    struct Entry: Equatable {
        enum Kind: Equatable {
            case text
            case media(uploaded: Bool)
        }
        let id: UUID
        let seq: Int
        let kind: Kind
    }

    enum Decision: Equatable {
        case postText(UUID)
        case postMedia(UUID)
        case wait     // the head of the line isn't ready (still uploading, or its POST is in flight)
        case idle     // nothing left to post in this chat
    }

    /// What to do next for one chat.
    /// - `failed`: items that gave up (bubble shows Retry). They don't hold up the line — one bad
    ///   upload must not freeze the chat — and rejoin it if the user retries.
    /// - `awaitingResult`: media whose POST is in flight; nothing after it may post until it
    ///   resolves, or the server could stamp the later one first.
    static func next(entries: [Entry], failed: Set<UUID>, awaitingResult: Set<UUID>) -> Decision {
        let ordered = entries.sorted { ($0.seq, $0.id.uuidString) < ($1.seq, $1.id.uuidString) }
        for entry in ordered where !failed.contains(entry.id) {
            if awaitingResult.contains(entry.id) { return .wait }
            switch entry.kind {
            case .text: return .postText(entry.id)
            case .media(let uploaded): return uploaded ? .postMedia(entry.id) : .wait
            }
        }
        return .idle
    }

    private static let counterKey = "sendOrderSequence"

    /// Monotonic across launches (persisted), shared by text and media, so a text queued after a
    /// photo always sorts after it — even if the app was killed and relaunched between the two.
    /// Items queued by an older build have no seq and sort as 0, i.e. ahead of anything new.
    @MainActor
    static func nextSeq(defaults: UserDefaults = .standard) -> Int {
        let next = defaults.integer(forKey: counterKey) + 1
        defaults.set(next, forKey: counterKey)
        return next
    }
}
