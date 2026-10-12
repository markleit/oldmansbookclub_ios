import SwiftUI

// #178 — drives the share sheet: load what was shared + the user's book chats in parallel,
// then send everything to the chosen chat. Since #204 PR 10 the sending is handed off — queued in
// the shared inbox, uploads given to iOS — and the sheet closes at once (ShareSender).
@MainActor
final class ShareModel: ObservableObject {
    enum Phase: Equatable {
        case loading
        case signedOut
        case failedToLoad(String)
        case ready
        case sending(done: Int, total: Int, label: String)
        case failedToSend(String)
    }

    @Published var phase: Phase = .loading
    @Published var items: [SharedItem] = []
    @Published var sections: [ShareClubSection] = []
    @Published var caption = ""

    private let api = ShareAPI.current()
    private var completion: () -> Void = {}
    /// Set once a send starts; a Retry resumes from the step that failed, so nothing that was
    /// already delivered is posted twice. (Caption editing is locked from then on.)
    private(set) var remaining: [SharePlan.Step]?
    private var total = 0

    var photoCount: Int { items.filter { if case .photo = $0 { return true } else { return false } }.count }

    func start(context: NSExtensionContext?, onDone: @escaping () -> Void) async {
        completion = onDone
        guard let api else { phase = .signedOut; return }
        async let shared = SharedItemLoader.load(from: context)
        do {
            async let books = api.books()
            async let clubs = api.clubs()
            sections = SharePlan.sections(books: try await books, clubs: try await clubs)
            items = await shared
            phase = items.isEmpty ? .failedToLoad("There's nothing here OMBC can send yet — photos, links and text are supported.") : .ready
        } catch ShareError.signedOut {
            phase = .signedOut
        } catch {
            _ = await shared
            phase = .failedToLoad(error.localizedDescription)
        }
    }

    func send(to book: ShareBook) async {
        guard let api else { phase = .signedOut; return }
        let photos: [Data] = items.compactMap { if case .photo(_, let jpeg, _) = $0 { return jpeg } else { return nil } }
        let kinds: [SharePlan.Kind] = items.map {
            switch $0 {
            case .photo: return .photo
            case .link(_, let url): return .link(url)
            case .text(_, let text): return .text(text)
            }
        }
        let steps = SharePlan.steps(for: kinds, caption: caption)
        remaining = steps
        // #204 PR 10 — queued and handed to iOS, then the sheet closes: no waiting on uploads.
        phase = .sending(done: 0, total: steps.count, label: "Sending…")
        await ShareSender.send(steps, photos: photos, to: book, api: api)
        completion()
    }
}
