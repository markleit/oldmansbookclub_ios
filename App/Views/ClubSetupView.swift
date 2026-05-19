import SwiftUI

struct ClubSetupView: View {
    @EnvironmentObject var auth: AuthViewModel
    @State private var clubName = ""
    @State private var showBrowse = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                Image(systemName: "books.vertical.fill")
                    .font(.system(size: 64))
                    .foregroundColor(.primary)

                Text("Start or Join a Club")
                    .font(.largeTitle)
                    .bold()

                Text("Create your own book club, or browse existing clubs to request access.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)

                TextField("Club name", text: $clubName)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, 40)
                    .autocorrectionDisabled()

                if auth.isLoading {
                    ProgressView()
                } else {
                    VStack(spacing: 12) {
                        Button("Create Club") {
                            auth.completeClubSetup(clubName: clubName.trimmingCharacters(in: .whitespaces))
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(clubName.trimmingCharacters(in: .whitespaces).isEmpty)

                        Button("Browse Existing Clubs") {
                            showBrowse = true
                        }
                        .foregroundColor(.accentColor)
                    }
                }

                if let error = auth.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }

                Spacer()
            }
            .navigationDestination(isPresented: $showBrowse) {
                BrowseClubsView()
            }
        }
    }
}
