import SwiftUI

struct BookDetailView: View {
    @StateObject private var viewModel: BookViewModel

    init(book: Book) {
        _viewModel = StateObject(wrappedValue: BookViewModel(book: book))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Rectangle()
                    .fill(Color.gray.opacity(0.3))
                    .frame(height: 220)
                    .cornerRadius(8)

                Text(viewModel.book.title)
                    .font(.title2)
                    .bold()

                Text("by \(viewModel.book.author)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Divider()

                Text("(Placeholder for book summary, reading progress, and comments)")
                    .foregroundColor(.secondary)
            }
            .padding()
        }
        .navigationTitle(viewModel.book.title)
    }
}

struct BookDetailView_Previews: PreviewProvider {
    static var previews: some View {
        BookDetailView(book: Book(id: UUID(), title: "Sample Book", author: "Author Name"))
    }
}
