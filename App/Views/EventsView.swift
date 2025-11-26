import SwiftUI

struct EventsView: View {
    // Sample events
    private let events: [Event] = [
        Event(id: UUID(), title: "Monthly Meetup", date: Date().addingTimeInterval(86400 * 7), location: "Community Hall"),
        Event(id: UUID(), title: "Author Q&A", date: Date().addingTimeInterval(86400 * 14), location: "Library Room B")
    ]

    var body: some View {
        NavigationView {
            List(events) { event in
                VStack(alignment: .leading) {
                    Text(event.title).font(.headline)
                    Text(event.location ?? "").font(.subheadline).foregroundColor(.secondary)
                    Text(event.date, style: .date).font(.caption).foregroundColor(.secondary)
                }
                .padding(.vertical, 6)
            }
            .navigationTitle("Events")
        }
    }
}

struct EventsView_Previews: PreviewProvider {
    static var previews: some View {
        EventsView()
    }
}
