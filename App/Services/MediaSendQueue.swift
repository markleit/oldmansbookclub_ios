import Foundation

enum MediaQueueKind: String, Codable { case voice, photo, video }

struct MediaQueueItem: Codable, Identifiable {
    let id: UUID                  // matches the optimistic Message.id
    let bookId: UUID
    let clubId: UUID
    let kind: MediaQueueKind
    let fileName: String          // in MediaSendQueue.pendingDirectory
    let contentType: String       // "audio/mp4" | "image/jpeg" | "video/mp4"
    let durationSeconds: Int?     // voice only
    var uploadedMediaUrl: String? // set after blob upload; only SignalR remaining on retry
    var retryCount: Int

    var localFileUrl: URL {
        MediaSendQueue.pendingDirectory.appendingPathComponent(fileName)
    }
}

@MainActor
final class MediaSendQueue {
    static let shared = MediaSendQueue()

    private(set) var items: [MediaQueueItem] = []

    nonisolated static var pendingDirectory: URL {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PendingMedia", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private nonisolated static var queueFileUrl: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("media_queue.json")
    }

    private init() {
        migrateLegacyVoiceQueueIfPresent()
        load()
        sweepOrphans()
    }

    func enqueue(_ item: MediaQueueItem) {
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

    func resetRetry(id: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].retryCount = 0
        save()
    }

    // Moves a temp file (e.g. AVAudioRecorder output, or PhotosPicker video URL) into
    // the persistent queue directory. Returns the destination URL or nil on failure.
    func moveToQueue(from tempUrl: URL, extension ext: String) -> URL? {
        let fileName = UUID().uuidString + "." + ext
        let dest = MediaSendQueue.pendingDirectory.appendingPathComponent(fileName)
        do {
            try FileManager.default.moveItem(at: tempUrl, to: dest)
            return dest
        } catch {
            return nil
        }
    }

    // Writes new data (e.g. UIImage.jpegData) into the queue directory.
    func saveToQueue(data: Data, extension ext: String) -> URL? {
        let fileName = UUID().uuidString + "." + ext
        let dest = MediaSendQueue.pendingDirectory.appendingPathComponent(fileName)
        do {
            try data.write(to: dest, options: .atomic)
            return dest
        } catch {
            return nil
        }
    }

    func cleanupFile(for item: MediaQueueItem) {
        try? FileManager.default.removeItem(at: item.localFileUrl)
    }

    // Cleanup a specific file by name after a delay — used when the server echo
    // replaces an optimistic bubble; the delay gives the SAS URL time to start
    // loading and covers Azure Blob's eventual-consistency window.
    nonisolated func scheduleCleanup(fileName: String, delaySeconds: Int = 10) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delaySeconds))
            let path = MediaSendQueue.pendingDirectory.appendingPathComponent(fileName)
            try? FileManager.default.removeItem(at: path)
        }
    }

    // Delete files in PendingMedia/ that aren't referenced by any queue entry — catches
    // cases where the process died between queue removal and file cleanup.
    private func sweepOrphans() {
        let referenced = Set(items.map { $0.fileName })
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: MediaSendQueue.pendingDirectory, includingPropertiesForKeys: nil
        ) else { return }
        for url in files where !referenced.contains(url.lastPathComponent) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: Self.queueFileUrl, options: .atomic)
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.queueFileUrl),
              let decoded = try? JSONDecoder().decode([MediaQueueItem].self, from: data) else { return }
        // Drop items whose local file was purged (OS cleanup, reinstall, etc.)
        items = decoded.filter { FileManager.default.fileExists(atPath: $0.localFileUrl.path) }
        if items.count != decoded.count { save() }
    }

    // One-time migration from the old voice-only queue. Reads legacy voice_queue.json,
    // converts each item to a MediaQueueItem(kind: .voice), moves files from
    // PendingVoice/ to PendingMedia/, then deletes the old artifacts.
    private func migrateLegacyVoiceQueueIfPresent() {
        let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let legacyQueue = supportDir.appendingPathComponent("voice_queue.json")
        let legacyDir = supportDir.appendingPathComponent("PendingVoice", isDirectory: true)

        struct LegacyVoiceItem: Codable {
            let id: UUID; let bookId: UUID; let clubId: UUID
            let fileName: String; let duration: Int
            var uploadedMediaUrl: String?; var retryCount: Int
        }

        guard let data = try? Data(contentsOf: legacyQueue),
              let legacy = try? JSONDecoder().decode([LegacyVoiceItem].self, from: data) else {
            // No legacy queue — also clean up any leftover empty directory
            try? FileManager.default.removeItem(at: legacyDir)
            return
        }

        for item in legacy {
            let oldPath = legacyDir.appendingPathComponent(item.fileName)
            let newPath = MediaSendQueue.pendingDirectory.appendingPathComponent(item.fileName)
            try? FileManager.default.moveItem(at: oldPath, to: newPath)
        }

        let migrated = legacy.map {
            MediaQueueItem(
                id: $0.id, bookId: $0.bookId, clubId: $0.clubId,
                kind: .voice, fileName: $0.fileName,
                contentType: "audio/mp4", durationSeconds: $0.duration,
                uploadedMediaUrl: $0.uploadedMediaUrl, retryCount: $0.retryCount
            )
        }
        items = migrated
        save()

        try? FileManager.default.removeItem(at: legacyQueue)
        try? FileManager.default.removeItem(at: legacyDir)
    }
}
