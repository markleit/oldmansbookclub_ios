import Foundation

struct Club: Identifiable, Codable {
    let id: UUID
    var name: String
    var description: String?
}

enum BookStatus: String, Codable {
    case future, current, past
}

struct Book: Identifiable, Codable {
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
}

enum MessageType: String, Codable {
    case text = "Text"
    case voice = "Voice"
    case photo = "Photo"
}
