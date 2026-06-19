import SwiftUI

// Read-only book metadata, opened from the chat's ⋯ menu. Shows what we have
// immediately, then fetches /books/{id} — which lazily backfills Google Books
// metadata (description / year / pages / cover) the first time a book is viewed.
struct BookDetailsView: View {
    let book: Book
    @Environment(\.dismiss) private var dismiss
    @State private var details: Book
    @State private var isLoading = false

    init(book: Book) {
        self.book = book
        _details = State(initialValue: book)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top, spacing: 16) {
                        CachedBookCover(urlString: details.coverBlobUrl, width: 110, height: 165, cornerRadius: 8)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(details.title)
                                .font(.title3.bold())
                                .fixedSize(horizontal: false, vertical: true)
                            if !details.author.isEmpty {
                                Text(details.author).foregroundColor(.secondary)
                            }
                            if !metaParts.isEmpty {
                                Text(metaParts.joined(separator: " · "))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .padding(.top, 2)
                            }
                        }
                        Spacer(minLength: 0)
                    }

                    Divider()

                    if let desc = details.description, !cleaned(desc).isEmpty {
                        Text("About").font(.headline)
                        Text(cleaned(desc))
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if isLoading {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Fetching details…").foregroundColor(.secondary).font(.subheadline)
                        }
                    } else {
                        Text("No description available.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
                .padding()
            }
            .navigationTitle("Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await load() }
        }
    }

    private var metaParts: [String] {
        var parts: [String] = []
        if let y = details.publishedYear { parts.append(String(y)) }
        if let p = details.pageCount { parts.append("\(p) pages") }
        switch details.status {
        case .future: parts.append("Future read")
        case .current: parts.append("Currently reading")
        case .past: parts.append("Finished")
        }
        return parts
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        if let fetched = try? await APIClient.shared.bookDetails(id: book.id) {
            details = fetched
        }
    }

    // Google Books descriptions sometimes carry light HTML; strip tags + common
    // entities for clean display.
    private func cleaned(_ s: String) -> String {
        s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
