import SwiftUI

struct EventsView: View {
    @StateObject private var viewModel = EventsViewModel()

    var body: some View {
        NavigationView {
            Group {
                if viewModel.isLoading {
                    ProgressView()
                } else if let error = viewModel.errorMessage {
                    Text(error).foregroundColor(.secondary)
                } else if viewModel.events.isEmpty {
                    Text("No upcoming events.")
                        .foregroundColor(.secondary)
                        .padding()
                } else {
                    List(viewModel.events) { event in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(event.title).font(.headline)
                            if let location = event.location {
                                Text(location).font(.subheadline).foregroundColor(.secondary)
                            }
                            Text(event.date, style: .date).font(.caption).foregroundColor(.secondary)
                        }
                        .padding(.vertical, 6)
                    }
                }
            }
            .navigationTitle("Events")
            .task { await viewModel.load() }
        }
    }
}

struct EventsView_Previews: PreviewProvider {
    static var previews: some View {
        EventsView()
    }
}
