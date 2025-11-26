import Foundation

struct Club: Identifiable, Codable {
    let id: UUID
    var name: String
    var description: String
    var coverURL: URL? = nil
}

struct Book: Identifiable, Codable {
    let id: UUID
    var title: String
    var author: String
    var coverURL: URL? = nil
}

struct Event: Identifiable, Codable {
    let id: UUID
    var title: String
    var date: Date
    var location: String?
}

struct User: Identifiable, Codable {
    let id: UUID
    var name: String
    var email: String?
}
