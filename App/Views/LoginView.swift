import AuthenticationServices
import SwiftUI

struct LoginView: View {
    @EnvironmentObject var auth: AuthViewModel
    @State private var showDemoLogin = false
    @State private var passphraseInput = ""

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "books.vertical.fill")
                .font(.system(size: 64))
                .foregroundColor(.primary)
                .padding(16)
                .contentShape(Rectangle())
                .onLongPressGesture(minimumDuration: 2) {
                    showDemoLogin = true
                }

            Text("Old Man's Book Club")
                .font(.largeTitle)
                .bold()

            Text("Read together. Discuss loudly.")
                .font(.subheadline)
                .foregroundColor(.secondary)

            Spacer()

            if auth.isLoading {
                ProgressView()
            } else {
                SignInWithAppleButton(.signIn) { request in
                    request.requestedScopes = [.fullName, .email]
                } onCompletion: { result in
                    auth.handleAppleSignIn(result)
                }
                .signInWithAppleButtonStyle(.black)
                .frame(height: 50)
                .padding(.horizontal, 40)
            }

            #if DEBUG
            // Settings (where this control normally lives) is only reachable once signed in — but
            // a fresh install on a device defaults to production, and production has no dev-login
            // (#120: AuthController 404s it outside Development). Without this, there is no way
            // to reach a local server before authenticating: production rejects Dev Login, and
            // there is no route to Settings to point elsewhere. Same override key as Settings, so
            // either screen sees the other's change.
            DebugServerControl()
                .padding(.horizontal, 40)

            VStack(spacing: 8) {
                Button("Dev Login (Debug)") {
                    auth.devLogin()
                }
                Button("Simulate New User") {
                    auth.needsClubSetup = true
                }
                Button("Simulate Pending Approval") {
                    auth.pendingApprovalClubName = "Test Book Club"
                }
                Button("Simulate Declined") {
                    auth.declinedClubName = "Test Book Club"
                }
            }
            .font(.caption)
            .foregroundColor(.secondary)
            #endif

            if let error = auth.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 40)
            }

            Spacer().frame(height: 40)
        }
        .alert("Reviewer Access", isPresented: $showDemoLogin) {
            SecureField("Passphrase", text: $passphraseInput)
            Button("Sign In") {
                let p = passphraseInput
                passphraseInput = ""
                auth.demoLogin(passphrase: p)
            }
            Button("Cancel", role: .cancel) { passphraseInput = "" }
        } message: {
            Text("Enter the reviewer passphrase to continue.")
        }
    }
}
