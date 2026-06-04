import Foundation

struct VoiceQueueItem: Codable, Identifiable {
    let id: UUID            // matches the optimistic Message.id
    let bookId: UUID
    let clubId: UUID
    let fileName: String    // filename only — full path computed from pendingDirectory
    let duration: Int
    var uploadedMediaUrl: String?   // set after upload succeeds; only SignalR needed on retry
    var retryCount: Int

    var localFileUrl: URL {
        VoiceSendQueue.pendingDirectory.appendingPathComponent(fileName)
    }
}

@MainActor
final class VoiceSendQueue {
    static let shared = VoiceSendQueue()

    private(set) var items: [VoiceQueueItem] = []

    nonisolated static var pendingDirectory: URL {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PendingVoice", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private nonisolated static var queueFileUrl: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("voice_queue.json")
    }

    private init() { load() }

    func enqueue(_ item: VoiceQueueItem) {
        items.append(item)
        save()
    }

    func remove(id: UUID) {
        items.removeAll { $0.id == id }
        save()
    }

    func markUploaded(id: UUID, mediaUrl: String) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].uploadedMediaUrl = mediaUrl
        save()
    }

    func incrementRetry(id: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].retryCount += 1
        save()
    }

    // Moves the temp recording to persistent storage. Returns the destination URL or nil on failure.
    func moveToQueue(from tempUrl: URL) -> URL? {
        let fileName = UUID().uuidString + ".m4a"
        let dest = VoiceSendQueue.pendingDirectory.appendingPathComponent(fileName)
        do {
            try FileManager.default.moveItem(at: tempUrl, to: dest)
            return dest
        } catch {
            return nil
        }
    }

    func cleanupFile(for item: VoiceQueueItem) {
        try? FileManager.default.removeItem(at: item.localFileUrl)
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: Self.queueFileUrl, options: .atomic)
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.queueFileUrl),
              let decoded = try? JSONDecoder().decode([VoiceQueueItem].self, from: data) else { return }
        // Drop items whose audio files were purged (OS tmp cleanup, reinstall, etc.)
        items = decoded.filter { FileManager.default.fileExists(atPath: $0.localFileUrl.path) }
        if items.count != decoded.count { save() }
    }
}
