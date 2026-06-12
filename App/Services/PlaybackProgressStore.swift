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
    }

    func position(for id: UUID) -> Double { states[id.uuidString]?.position ?? 0 }
    func isCompleted(_ id: UUID) -> Bool { states[id.uuidString]?.completed ?? false }

    func set(id: UUID, position: Double, completed: Bool) {
        states[id.uuidString] = State(position: max(0, position), completed: completed)
        persist()
    }

    // Move the resume point by dragging the thumb on an idle bubble; clears the
    // completed/green state since the user has repositioned within the message.
    func setPosition(id: UUID, fraction: Double, duration: Int) {
        guard duration > 0 else { return }
        let pos = max(0, min(1, fraction)) * Double(duration)
        states[id.uuidString] = State(position: pos, completed: false)
        persist()
    }

    // Reset to the start (used when replaying a completed message — green clears).
    func clear(_ id: UUID) {
        states[id.uuidString] = State(position: 0, completed: false)
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(states) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
