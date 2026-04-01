import SwiftUI

struct CreateEventView: View {
    @Environment(\.dismiss) private var dismiss
    let clubId: UUID
    var onCreated: (Event) -> Void

    @State private var title = ""
    @State private var date = Date().addingTimeInterval(86400 * 7) // default: 1 week from now
    @State private var location = ""
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationView {
            Form {
                Section("Event Title") {
                    TextField("e.g. Monthly Meetup", text: $title)
                }

                Section("Date & Time") {
                    DatePicker("When", selection: $date, minimumDate: Date())
                        .datePickerStyle(.graphical)
                }

                Section("Location (optional)") {
                    TextField("e.g. Community Hall", text: $location)
                }

                if let error = errorMessage {
                    Section {
                        Text(error).foregroundColor(.red).font(.caption)
                    }
                }
            }
            .navigationTitle("New Event")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isLoading {
                        ProgressView()
                    } else {
                        Button("Create") { Task { await create() } }
                            .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
    }

    private func create() async {
        isLoading = true
        errorMessage = nil
        do {
            let event = try await APIClient.shared.createEvent(
                clubId: clubId,
                title: title.trimmingCharacters(in: .whitespaces),
                date: date,
                location: location.trimmingCharacters(in: .whitespaces).isEmpty
                    ? nil
                    : location.trimmingCharacters(in: .whitespaces)
            )
            onCreated(event)
            dismiss()
        } catch {
            errorMessage = "Failed to create event. Please try again."
        }
        isLoading = false
    }
}
