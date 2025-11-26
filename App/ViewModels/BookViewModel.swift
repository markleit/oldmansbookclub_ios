import Foundation

final class BookViewModel: ObservableObject {
    @Published var book: Book

    init(book: Book) {
        self.book = book
    }
}
