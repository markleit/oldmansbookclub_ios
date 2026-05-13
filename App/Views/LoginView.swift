import AuthenticationServices
import SwiftUI

struct LoginView: View {
    @EnvironmentObject var auth: AuthViewModel
    @State private var showDemoLogin = false
    @State private var passphraseInput = ""
    @State private var showEULA = !UserDefaults.standard.bool(forKey: "hasAcceptedEULA")

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

            #if targetEnvironment(simulator)
            Button("Dev Login (Simulator)") {
                auth.devLogin()
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
        .fullScreenCover(isPresented: $showEULA) {
            EULAView { showEULA = false }
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
