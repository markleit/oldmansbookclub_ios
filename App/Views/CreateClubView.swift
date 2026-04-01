import SwiftUI

struct CreateClubView: View {
    @Environment(\.dismiss) private var dismiss
    var onCreated: (Club) -> Void

    @State private var name = ""
    @State private var description = ""
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationView {
            Form {
                Section("Club Name") {
                    TextField("e.g. Evening Readers", text: $name)
                }

                Section("Description") {
                    TextField("What does your club read?", text: $description, axis: .vertical)
                        .lineLimit(3...6)
                }

                if let error = errorMessage {
                    Section {
                        Text(error).foregroundColor(.red).font(.caption)
                    }
                }
            }
            .navigationTitle("New Club")
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
                            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
    }

    private func create() async {
        isLoading = true
        errorMessage = nil
        do {
            let club = try await APIClient.shared.createClub(
                name: name.trimmingCharacters(in: .whitespaces),
                description: description.trimmingCharacters(in: .whitespaces).isEmpty
                    ? nil
                    : description.trimmingCharacters(in: .whitespaces)
            )
            onCreated(club)
            dismiss()
        } catch {
            errorMessage = "Failed to create club. Please try again."
        }
        isLoading = false
    }
}
