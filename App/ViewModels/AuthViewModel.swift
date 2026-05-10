import AuthenticationServices
import Foundation

@MainActor
final class AuthViewModel: ObservableObject {
    @Published var isAuthenticated = TokenStore.shared.isAuthenticated
    @Published var isLoading = false
    @Published var errorMessage: String?

    func handleAppleSignIn(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .failure:
            errorMessage = "Sign in was cancelled."
        case .success(let auth):
            guard
                let credential = auth.credential as? ASAuthorizationAppleIDCredential,
                let tokenData = credential.identityToken,
                let identityToken = String(data: tokenData, encoding: .utf8)
            else {
                errorMessage = "Unable to read Apple credentials."
                return
            }

            let displayName: String
            if let first = credential.fullName?.givenName, let last = credential.fullName?.familyName {
                displayName = "\(first) \(last)".trimmingCharacters(in: .whitespaces)
            } else {
                displayName = TokenStore.shared.displayName ?? "Book Club Member"
            }
            let email = credential.email

            isLoading = true
            errorMessage = nil

            Task {
                defer { isLoading = false }
                do {
                    let response = try await APIClient.shared.signInWithApple(
                        identityToken: identityToken,
                        displayName: displayName,
                        email: email
                    )
                    TokenStore.shared.save(
                        token: response.accessToken,
                        userId: response.user.id,
                        displayName: response.user.displayName,
                        nickname: response.user.nickname,
                        avatarUrl: response.user.avatarUrl,
                        isAdmin: response.user.isAdmin
                    )
                    isAuthenticated = true
                } catch APIError.pendingApproval {
                    errorMessage = "Your account is pending club approval. Try again once the admin has added you."
                } catch {
                    errorMessage = "Sign in failed. Please try again."
                }
            }
        }
    }

    func signOut() {
        TokenStore.shared.clear()
        isAuthenticated = false
    }

    func demoLogin(passphrase: String) {
        isLoading = true
        errorMessage = nil
        Task {
            defer { isLoading = false }
            do {
                let response = try await APIClient.shared.demoLogin(passphrase: passphrase)
                TokenStore.shared.save(
                    token: response.accessToken,
                    userId: response.user.id,
                    displayName: response.user.displayName,
                    nickname: response.user.nickname,
                    avatarUrl: response.user.avatarUrl,
                    isAdmin: response.user.isAdmin
                )
                isAuthenticated = true
            } catch {
                errorMessage = "Invalid passphrase."
            }
        }
    }

    #if targetEnvironment(simulator)
    func devLogin() {
        isLoading = true
        errorMessage = nil
        Task {
            defer { isLoading = false }
            do {
                let response = try await APIClient.shared.devLogin(displayName: "Mark")
                TokenStore.shared.save(
                    token: response.accessToken,
                    userId: response.user.id,
                    displayName: response.user.displayName,
                    nickname: response.user.nickname,
                    avatarUrl: response.user.avatarUrl,
                    isAdmin: response.user.isAdmin
                )
                isAuthenticated = true
            } catch {
                errorMessage = "Dev login failed: \(error)"
            }
        }
    }
    #endif
}
