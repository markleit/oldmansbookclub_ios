import Foundation

// #204 — every unsent message, on disk, for every chat and every message type.
//
// Replaces TextSendQueue (UserDefaults) + MediaSendQueue (a JSON file + PendingMedia/), which were
// two stores with two shapes, owned by the chat screen. Lives in the App Group container so the
// Share extension can add to it later (PR 10). Layout:
//
//   Outbox/items.json   — the items, plus the last tap time handed out
//   Outbox/files/       — media for voice/photo/video items (by fileName)
//   Outbox/requests/    — request bodies handed to iOS's background transfer, which uploads from
//                         a file (a background session can't take an in-memory body)
@MainActor
final class Outbox {
    let directory: URL
    private(set) var items: [SendItem] = []
    private var lastSentAt: Date?

    private struct Stored: Codable {
        var items: [SendItem]
        var lastSentAt: Date?
    }

    var filesDirectory: URL { directory.appendingPathComponent("files", isDirectory: true) }
    var requestsDirectory: URL { directory.appendingPathComponent("requests", isDirectory: true) }
    private var storeURL: URL { directory.appendingPathComponent("items.json") }

    /// The App Group container when the app has one (it does, in every real build), else the
    /// app's own Application Support — so a unit-test host or a misconfigured build still works.
    nonisolated static func defaultDirectory() -> URL {
        let base = SharedContainer.appGroupId
            .flatMap { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Outbox", isDirectory: true)
    }

    init(directory: URL = Outbox.defaultDirectory()) {
        self.directory = directory
        for dir in [directory, filesDirectory, requestsDirectory] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        load()
        sweepOrphans()
    }

    // MARK: - Items

    func item(_ id: UUID) -> SendItem? { items.first { $0.id == id } }

    func add(_ item: SendItem) {
        items.append(item)
        save()
    }

    func update(_ id: UUID, _ change: (inout SendItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
        save()
    }

    /// Drops the item. Its media file goes after `fileGrace` — the bubble that's being swapped for
    /// the confirmed message may still be drawing it for a moment. An orphan left behind by a crash
    /// in that window is swept on the next launch.
    func remove(_ id: UUID, fileGrace: TimeInterval = 10) {
        guard let item = item(id) else { return }
        items.removeAll { $0.id == id }
        save()
        removeRequestBodies(for: id)
        if let name = item.fileName {
            let url = fileURL(name)
            if fileGrace <= 0 {
                try? FileManager.default.removeItem(at: url)
            } else {
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(fileGrace))
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }
    }

    /// Fresh local state for a hermetic UI test (#204 T3) — never called in a release build.
    func removeAll() {
        items = []
        lastSentAt = nil
        try? FileManager.default.removeItem(at: directory)
        for dir in [directory, filesDirectory, requestsDirectory] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        save()
    }

    /// The tap time for a new send: now, but always strictly after the previous one — two taps in
    /// the same millisecond, or a clock that stepped backwards, must not swap their order in the chat.
    func nextSentAt(now: Date = Date()) -> Date {
        let next = max(now, (lastSentAt ?? .distantPast).addingTimeInterval(0.001))
        lastSentAt = next
        save()
        return next
    }

    // MARK: - Files

    func fileURL(_ name: String) -> URL { filesDirectory.appendingPathComponent(name) }

    /// Moves (or copies) a file the app produced — a recording, a compressed video — into the outbox.
    func importFile(at url: URL, extension ext: String, move: Bool = true) throws -> String {
        let name = UUID().uuidString + "." + ext
        if move {
            try FileManager.default.moveItem(at: url, to: fileURL(name))
        } else {
            try FileManager.default.copyItem(at: url, to: fileURL(name))
        }
        return name
    }

    func importData(_ data: Data, extension ext: String) throws -> String {
        let name = UUID().uuidString + "." + ext
        try data.write(to: fileURL(name), options: .atomic)
        return name
    }

    func fileExists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(name).path)
    }

    /// Writes a background request's body to a file (attempt-numbered, so a retry never rewrites a
    /// file iOS may still be reading for the previous attempt).
    func writeRequestBody(_ data: Data, for id: UUID, attempt: Int) throws -> URL {
        let url = requestsDirectory.appendingPathComponent("\(id.uuidString)-\(attempt).json")
        try data.write(to: url, options: .atomic)
        return url
    }

    private func removeRequestBodies(for id: UUID) {
        let prefix = id.uuidString + "-"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: requestsDirectory.path)) ?? []
        for name in names where name.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: requestsDirectory.appendingPathComponent(name))
        }
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return }
        items = stored.items
        lastSentAt = stored.lastSentAt
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(Stored(items: items, lastSentAt: lastSentAt)) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }

    /// Files and request bodies nothing refers to any more — left by a crash between removing an
    /// item and deleting its file.
    private func sweepOrphans() {
        let referenced = Set(items.compactMap(\.fileName))
        for name in (try? FileManager.default.contentsOfDirectory(atPath: filesDirectory.path)) ?? []
        where !referenced.contains(name) {
            try? FileManager.default.removeItem(at: fileURL(name))
        }
        let live = Set(items.map { $0.id.uuidString })
        for name in (try? FileManager.default.contentsOfDirectory(atPath: requestsDirectory.path)) ?? []
        where !live.contains(String(name.prefix(36))) {
            try? FileManager.default.removeItem(at: requestsDirectory.appendingPathComponent(name))
        }
    }

    // MARK: - Taking over 2.1's queues

    private struct LegacyText: Decodable {
        let clientId: UUID; let bookId: UUID; let clubId: UUID; let body: String
        let parentMessageId: UUID?; let queuedAt: Date; let seq: Int?
    }

    private struct LegacyMedia: Decodable {
        let id: UUID; let bookId: UUID; let clubId: UUID; let kind: String; let fileName: String
        let contentType: String; let durationSeconds: Int?; let uploadedMediaUrl: String?
        let parentMessageId: UUID?; let seq: Int?
    }

    /// Moves anything 2.1 had queued (TextSendQueue, MediaSendQueue) into the outbox, once, and
    /// deletes the old stores. Their send order (`seq`) becomes strictly increasing tap times, and
    /// a media item whose blob was already uploaded keeps its URL — only its post remains.
    /// Returns how many items were taken over.
    @discardableResult
    func migrateLegacy(defaults: UserDefaults = .standard, supportDirectory: URL? = nil, now: Date = Date()) -> Int {
        let support = supportDirectory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let legacyMediaFile = support.appendingPathComponent("media_queue.json")
        let legacyMediaDir = support.appendingPathComponent("PendingMedia", isDirectory: true)

        let texts = defaults.data(forKey: "pendingTextSends")
            .flatMap { try? JSONDecoder().decode([LegacyText].self, from: $0) } ?? []
        let media = (try? Data(contentsOf: legacyMediaFile))
            .flatMap { try? JSONDecoder().decode([LegacyMedia].self, from: $0) } ?? []

        struct Pending { let id: UUID; let seq: Int; let when: Date; let make: (Date) -> SendItem? }
        var pending: [Pending] = texts.map { t in
            Pending(id: t.clientId, seq: t.seq ?? 0, when: t.queuedAt) { sentAt in
                SendItem(id: t.clientId, bookId: t.bookId, clubId: t.clubId, kind: .text, sentAt: sentAt,
                         body: t.body, parentMessageId: t.parentMessageId)
            }
        }
        for m in media {
            let source = legacyMediaDir.appendingPathComponent(m.fileName)
            let created = (try? FileManager.default.attributesOfItem(atPath: source.path)[.creationDate] as? Date) ?? now
            pending.append(Pending(id: m.id, seq: m.seq ?? 0, when: created) { [self] sentAt in
                // A file the OS purged can't be sent — and there's no bubble to explain it to, so
                // it's dropped (2.1 dropped it the same way on load).
                guard let kind = SendItem.Kind(rawValue: m.kind),
                      FileManager.default.fileExists(atPath: source.path),
                      (try? FileManager.default.moveItem(at: source, to: fileURL(m.fileName))) != nil else { return nil }
                return SendItem(id: m.id, bookId: m.bookId, clubId: m.clubId, kind: kind, sentAt: sentAt,
                                fileName: m.fileName, contentType: m.contentType, durationSeconds: m.durationSeconds,
                                parentMessageId: m.parentMessageId, mediaUrl: m.uploadedMediaUrl)
            })
        }

        var taken = 0
        let ordered = pending.sorted { (a: Pending, b: Pending) -> Bool in
            a.seq != b.seq ? a.seq < b.seq : a.when < b.when
        }
        for p in ordered where !items.contains(where: { $0.id == p.id }) {
            if let item = p.make(nextSentAt(now: p.when)) {
                items.append(item)
                taken += 1
            }
        }
        save()

        defaults.removeObject(forKey: "pendingTextSends")
        try? FileManager.default.removeItem(at: legacyMediaFile)
        try? FileManager.default.removeItem(at: legacyMediaDir)
        return taken
    }
}
