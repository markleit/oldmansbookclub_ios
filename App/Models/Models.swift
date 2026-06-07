import Foundation

struct Club: Identifiable, Codable {
    let id: UUID
    var name: String
    var description: String?
    var isClubAdmin: Bool = false
}

extension Club {
    enum CodingKeys: String, CodingKey {
        case id, name, description, isClubAdmin
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        isClubAdmin = try c.decodeIfPresent(Bool.self, forKey: .isClubAdmin) ?? false
    }
}

enum BookStatus: String, Codable {
    case future, current, past
}

struct Book: Identifiable, Codable, Hashable {
    let id: UUID
    var clubId: UUID
    var title: String
    var author: String
    var coverBlobUrl: String?
    var addedAt: Date
    var finishedAt: Date?
    var status: BookStatus
}

struct User: Identifiable, Codable {
    let id: UUID
    var displayName: String
    var nickname: String?
    var avatarUrl: String?
}

enum MessageSendState: String, Codable {
    case sending, failed
}

struct Message: Identifiable, Codable {
    let id: UUID
    var clubId: UUID
    var senderId: UUID
    var senderName: String
    var senderAvatarUrl: String?
    var type: MessageType
    var body: String?
    var mediaUrl: String?
    var durationSeconds: Int?
    var sentAt: Date
    var isDeleted: Bool = false
    var isForwarded: Bool = false
    var sendState: MessageSendState? = nil  // local only — never sent to or received from server
    var clientId: UUID? = nil               // local only — set on SignalR echo for dedup, nil elsewhere

    enum CodingKeys: String, CodingKey {
        case id, clubId, senderId, senderName, senderAvatarUrl, type, body, mediaUrl, durationSeconds, sentAt, isDeleted, isForwarded, clientId
    }
}

extension Message {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        clubId = try c.decode(UUID.self, forKey: .clubId)
        senderId = try c.decode(UUID.self, forKey: .senderId)
        senderName = try c.decode(String.self, forKey: .senderName)
        senderAvatarUrl = try c.decodeIfPresent(String.self, forKey: .senderAvatarUrl)
        type = try c.decode(MessageType.self, forKey: .type)
        body = try c.decodeIfPresent(String.self, forKey: .body)
        mediaUrl = try c.decodeIfPresent(String.self, forKey: .mediaUrl)
        durationSeconds = try c.decodeIfPresent(Int.self, forKey: .durationSeconds)
        sentAt = try c.decode(Date.self, forKey: .sentAt)
        isDeleted = try c.decodeIfPresent(Bool.self, forKey: .isDeleted) ?? false
        isForwarded = try c.decodeIfPresent(Bool.self, forKey: .isForwarded) ?? false
        // Present on the sender's own messages (REST + SignalR echo); lets load()
        // reconcile a confirmed server message with its optimistic copy when the
        // live SignalR echo was missed (e.g. app backgrounded mid-send).
        clientId = try c.decodeIfPresent(UUID.self, forKey: .clientId)
    }
}

struct SavedMessage: Identifiable, Decodable {
    let id: UUID
    let messageId: UUID
    let senderName: String
    let type: MessageType
    let body: String?
    let mediaUrl: String?
    let durationSeconds: Int?
    let sentAt: Date
    let savedAt: Date
    let isDeleted: Bool

    enum CodingKeys: String, CodingKey {
        case id = "savedId"
        case messageId, senderName, type, body, mediaUrl, durationSeconds, sentAt, savedAt, isDeleted
    }
}

enum MessageType: String, Codable {
    case text = "Text"
    case voice = "Voice"
    case photo = "Photo"
    case video = "Video"
    case unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = MessageType(rawValue: raw) ?? .unknown
    }
}
