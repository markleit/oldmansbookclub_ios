import Foundation

struct Club: Identifiable, Codable {
    let id: UUID
    var name: String
    var description: String?
    var coverBlobUrl: String?
}

struct Event: Identifiable, Codable {
    let id: UUID
    var clubId: UUID
    var title: String
    var date: Date
    var location: String?
}

struct User: Identifiable, Codable {
    let id: UUID
    var displayName: String
}

struct Message: Identifiable, Codable {
    let id: UUID
    var clubId: UUID
    var senderId: UUID
    var senderName: String
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
