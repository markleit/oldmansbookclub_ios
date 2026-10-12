import Foundation

/// One upload link fetched in advance (the server's VideoSlot): a create-only link for one video.
struct VideoSlot: Codable, Equatable {
    let uploadUrl: String
    let mediaUrl: String
    let fetchedAt: Date
    let expiresAt: Date
}

// #204 design v2 — upload slots kept on the phone, so a video sent with no network can be handed to
// iOS at the tap like any other message (2.2 (6): offline, a video's upload had to wait for the
// network to be reserved, reached iOS only from the background, and waited for the app to open).
//
// The rules (agreed 2026-10-12): 3 per club, topped up whenever the app is online — at launch, on
// coming back to the app, on opening a chat, and after one is used. Any slot older than a day is
// swapped for a fresh one then, and a video takes the newest, so in practice it has about 6 days to
// wait for the network. None left → the video waits for the network and the app, as before.
// Signing out discards them (they belong to that sign-in; the server drops what they'd create).
//
// A small JSON file beside the outbox, read and written on every use: no copy in memory to drift.
struct VideoSlots {
    static let perClub = 3
    /// Older than this, a slot is swapped for a fresh one whenever the app is online.
    static let replaceAfter: TimeInterval = 24 * 3600

    let file: URL

    init(directory: URL) { file = directory.appendingPathComponent("video-slots.json") }

    static func removeAll(in directory: URL) {
        try? FileManager.default.removeItem(at: VideoSlots(directory: directory).file)
    }

    func all() -> [UUID: [VideoSlot]] {
        guard let data = try? Data(contentsOf: file),
              let stored = try? JSONDecoder().decode([String: [VideoSlot]].self, from: data) else { return [:] }
        return Dictionary(uniqueKeysWithValues: stored.compactMap { key, value in UUID(uuidString: key).map { ($0, value) } })
    }

    private func save(_ slots: [UUID: [VideoSlot]]) {
        let stored = Dictionary(uniqueKeysWithValues: slots.map { ($0.key.uuidString, $0.value) })
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(stored).write(to: file, options: .atomic)
    }

    /// The newest unexpired slot for this club, removed from the store — or nil (none left).
    mutating func take(clubId: UUID, now: Date) -> VideoSlot? {
        var slots = all()
        let usable = (slots[clubId] ?? []).filter { $0.expiresAt > now }
        guard let newest = usable.max(by: { $0.fetchedAt < $1.fetchedAt }) else { return nil }
        slots[clubId] = usable.filter { $0 != newest }
        save(slots)
        return newest
    }

    /// How many to fetch to have `perClub` fresh ones (under a day old) for this club.
    func toFetch(clubId: UUID, now: Date) -> Int {
        let fresh = (all()[clubId] ?? []).filter { $0.expiresAt > now && now.timeIntervalSince($0.fetchedAt) < Self.replaceAfter }
        return max(0, Self.perClub - fresh.count)
    }

    /// Fresh slots in: those over a day old (or expired) go only now — a top-up that fails keeps
    /// what's there, still good for days.
    mutating func add(_ fetched: [VideoSlot], clubId: UUID, now: Date) {
        var slots = all()
        let fresh = (slots[clubId] ?? []).filter { $0.expiresAt > now && now.timeIntervalSince($0.fetchedAt) < Self.replaceAfter }
        slots[clubId] = fresh + fetched
        save(slots)
    }
}
