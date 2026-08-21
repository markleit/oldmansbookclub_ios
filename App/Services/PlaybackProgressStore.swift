import Foundation

// Per-voice-message playback position + "fully played" state, persisted to disk so a
// user can leave the chat / play other messages / relaunch the app and still resume
// where they left off. Keyed by message id.
//
// Note: grows with the number of voice messages ever played. Entries are tiny (~tens
// of bytes); for this app's scale that's fine. If it ever needs bounding, add an LRU
// cap keyed by last-touched timestamp.
@MainActor
final class PlaybackProgressStore: ObservableObject {
    static let shared = PlaybackProgressStore()

    struct State: Codable {
        var position: Double   // seconds
        var completed: Bool
    }

    @Published private var states: [String: State]
    private let key = "voicePlaybackProgress"

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([String: State].self, from: data) {
            states = decoded
        } else {
            states = [:]
        }
        dropIfNotMine()
    }

    // Positions belong to the account that listened (#119). This matters beyond tidiness: the
    // `completed` flags here are the source of the legacy heard-mark migration, so leaving one
    // account's flags in place would let them be adopted as the NEXT account's marks and pushed
    // to the server — routing around the scoping in HeardStore through a side door.
    private func dropIfNotMine() {
        guard AccountScope.ownerChanged("playbackProgress") else { return }
        states = [:]
        persist()
    }

    // Voice ids among `candidates` this device played to the end before #119 introduced an
    // outbox. Scoped on the way out so a migration can never adopt someone else's listening.
    func legacyHeardIds(among candidates: [UUID]) -> [UUID] {
        dropIfNotMine()
        return candidates.filter { states[$0.uuidString]?.completed == true }
    }

    func position(for id: UUID) -> Double { states[id.uuidString]?.position ?? 0 }
    func isCompleted(_ id: UUID) -> Bool { states[id.uuidString]?.completed ?? false }

    // `completed` is the sticky HEARD flag: once true it stays true (set on full
    // playback or "mark as heard"). Replays and re-scrubs never clear it — only an
    // explicit un-mark would.
    func set(id: UUID, position: Double, completed: Bool) {
        dropIfNotMine()
        let heard = (states[id.uuidString]?.completed ?? false) || completed
        states[id.uuidString] = State(position: max(0, position), completed: heard)
        persist()
    }

    // Move the resume point by dragging the thumb on an idle bubble. Keeps the
    // heard/green state (sticky).
    func setPosition(id: UUID, fraction: Double, duration: Int) {
        dropIfNotMine()
        guard duration > 0 else { return }
        let pos = max(0, min(1, fraction)) * Double(duration)
        states[id.uuidString] = State(position: pos, completed: states[id.uuidString]?.completed ?? false)
        persist()
    }

    // Mark voice messages fully heard without playing them ("mark all as heard").
    // Positions the thumb at the end + sets the green/completed state. One persist
    // for the whole batch. Items: (message id, duration in seconds).
    func markHeard(_ items: [(id: UUID, duration: Int)]) {
        dropIfNotMine()
        guard !items.isEmpty else { return }
        for item in items {
            let pos = item.duration > 0 ? Double(item.duration) : max(states[item.id.uuidString]?.position ?? 1, 1)
            states[item.id.uuidString] = State(position: pos, completed: true)
        }
        persist()
    }

    // Reset the resume position to the start (on replay) WITHOUT un-hearing — the
    // green/heard state is sticky and survives replays.
    func resetPosition(_ id: UUID) {
        dropIfNotMine()
        states[id.uuidString] = State(position: 0, completed: states[id.uuidString]?.completed ?? false)
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(states) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
