import Foundation

// #178 — the Share extension's pure decisions, kept free of UIKit/extension APIs so the app's
// unit tests can cover them (the extension itself has no test target).

struct ShareBook: Identifiable, Decodable, Hashable {
    let id: UUID
    let clubId: UUID
    let title: String
    let author: String
    let status: String   // "current" | "future" | "past"
}

struct ShareClub: Identifiable, Decodable {
    let id: UUID
    let name: String
}

struct ShareClubSection: Identifiable {
    let id: UUID
    let name: String
    let books: [ShareBook]
}

enum SharePlan {
    /// What was shared, minus the payload bytes.
    enum Kind: Equatable {
        case photo
        case link(URL)
        case text(String)
    }

    /// One message to post. `photo(n)` is the n-th photo in shared order.
    enum Step: Equatable {
        case text(String)
        case photo(Int)
    }

    /// Caption first when there are photos (it reads as the lead-in), then each photo in order.
    /// A link or text share folds the caption into that same message instead of sending two.
    static func steps(for kinds: [Kind], caption: String) -> [Step] {
        let note = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        var steps: [Step] = []
        var photoIndex = 0
        for kind in kinds {
            switch kind {
            case .photo:
                steps.append(.photo(photoIndex)); photoIndex += 1
            case .link(let url):
                steps.append(.text(note.isEmpty ? url.absoluteString : "\(note)\n\(url.absoluteString)"))
            case .text(let text):
                steps.append(.text(note.isEmpty ? text : "\(note)\n\n\(text)"))
            }
        }
        if photoIndex > 0, !note.isEmpty { steps.insert(.text(note), at: 0) }
        return steps
    }

    /// One section per club (clubs with no books omitted); within it the current read first,
    /// then upcoming, then past, alphabetical within each.
    static func sections(books: [ShareBook], clubs: [ShareClub]) -> [ShareClubSection] {
        func rank(_ book: ShareBook) -> Int {
            switch book.status {
            case "current": return 0
            case "future": return 1
            default: return 2
            }
        }
        func precedes(_ a: ShareBook, _ b: ShareBook) -> Bool {
            rank(a) != rank(b) ? rank(a) < rank(b) : a.title < b.title
        }
        return clubs.compactMap { club in
            let mine = books.filter { $0.clubId == club.id }.sorted(by: precedes)
            return mine.isEmpty ? nil : ShareClubSection(id: club.id, name: club.name, books: mine)
        }
    }
}
