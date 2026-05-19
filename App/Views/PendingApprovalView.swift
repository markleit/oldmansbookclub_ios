import AuthenticationServices
import SwiftUI

struct PendingApprovalView: View {
    @EnvironmentObject var auth: AuthViewModel
    let clubName: String
    let declined: Bool

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: declined ? "xmark.seal" : "clock.badge")
                .font(.system(size: 64))
                .foregroundColor(declined ? .red : .secondary)

            Text(declined ? "Request Declined" : "Request Pending")
                .font(.largeTitle)
                .bold()

            Text(declined
                ? "Your request to join **\(clubName)** was declined. You can try joining a different club or create your own."
                : "Your request to join **\(clubName)** is awaiting admin approval. Sign in below to check if you've been approved."
            )
            .font(.subheadline)
            .foregroundColor(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 40)

            if auth.isLoading {
                ProgressView()
            } else if declined {
                Button("Try a Different Club") {
                    auth.resetToClubSetup()
                }
                .buttonStyle(.borderedProminent)
            } else {
                SignInWithAppleButton(.signIn) { request in
                    request.requestedScopes = [.fullName, .email]
                } onCompletion: { result in
                    auth.handleAppleSignIn(result)
                }
                .signInWithAppleButtonStyle(.black)
                .frame(height: 50)
                .padding(.horizontal, 40)

                #if targetEnvironment(simulator)
                Button("Dev Check Status (Simulator)") {
                    auth.devLogin()
                }
                .font(.caption)
                .foregroundColor(.secondary)
                #endif
            }

            if let error = auth.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }

            Spacer()
        }
    }
}
