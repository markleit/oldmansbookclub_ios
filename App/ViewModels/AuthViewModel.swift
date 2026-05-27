import AuthenticationServices
import Foundation

@MainActor
final class AuthViewModel: ObservableObject {
    @Published var isAuthenticated: Bool
    @Published var needsClubSetup = false
    @Published var pendingApprovalClubName: String?
    @Published var declinedClubName: String?
    @Published var isLoading = false
    @Published var errorMessage: String?

    private var pendingIdentityToken: String?
    private var pendingDisplayName: String?
    private var pendingEmail: String?

    init() {
        if TokenStore.shared.isTokenExpired {
            TokenStore.shared.clear()
            isAuthenticated = false
        } else {
            isAuthenticated = TokenStore.shared.isAuthenticated
        }
        APIClient.shared.onUnauthorized = { [weak self] in
            Task { @MainActor [weak self] in self?.signOut() }
        }
    }

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
            let authorizationCode: String? = credential.authorizationCode.flatMap { String(data: $0, encoding: .utf8) }

            pendingIdentityToken = identityToken
            pendingDisplayName = displayName
            pendingEmail = email
            isLoading = true
            errorMessage = nil

            Task {
                defer { isLoading = false }
                do {
                    let response = try await APIClient.shared.signInWithApple(
                        identityToken: identityToken,
                        displayName: displayName,
                        email: email,
                        authorizationCode: authorizationCode
                    )
                    finishSignIn(response)
                } catch APIError.needsClubSetup {
                    needsClubSetup = true
                } catch APIError.pendingApproval(let clubName) {
                    pendingApprovalClubName = clubName
                } catch APIError.requestDeclined(let clubName) {
                    declinedClubName = clubName
                } catch {
                    errorMessage = "Sign in failed. Please try again."
                }
            }
        }
    }

    func requestToJoin(clubId: UUID) {
        #if targetEnvironment(simulator)
        if pendingIdentityToken == nil {
            needsClubSetup = false
            pendingApprovalClubName = "Old Man's Book Club"
            return
        }
        #endif
        guard let token = pendingIdentityToken, let name = pendingDisplayName else { return }
        isLoading = true
        errorMessage = nil
        Task {
            defer { isLoading = false }
            do {
                let response = try await APIClient.shared.signInWithApple(
                    identityToken: token, displayName: name, email: pendingEmail, joinClubId: clubId)
                needsClubSetup = false
                finishSignIn(response)
            } catch APIError.pendingApproval(let clubName) {
                needsClubSetup = false
                pendingApprovalClubName = clubName
            } catch APIError.requestDeclined(let clubName) {
                needsClubSetup = false
                declinedClubName = clubName
            } catch {
                errorMessage = "Could not submit request. Please try again."
            }
        }
    }

    func completeClubSetup(clubName: String) {
        #if targetEnvironment(simulator)
        if pendingIdentityToken == nil {
            needsClubSetup = false
            devLogin()
            return
        }
        #endif
        guard let token = pendingIdentityToken, let name = pendingDisplayName else { return }
        isLoading = true
        errorMessage = nil
        Task {
            defer { isLoading = false }
            do {
                let response = try await APIClient.shared.signInWithApple(
                    identityToken: token,
                    displayName: name,
                    email: pendingEmail,
                    clubName: clubName
                )
                needsClubSetup = false
                pendingIdentityToken = nil
                pendingDisplayName = nil
                pendingEmail = nil
                finishSignIn(response)
            } catch {
                errorMessage = "Could not create club. Please try again."
            }
        }
    }

    private func finishSignIn(_ response: APIClient.AuthResponse) {
        TokenStore.shared.save(
            token: response.accessToken,
            userId: response.user.id,
            displayName: response.user.displayName,
            nickname: response.user.nickname,
            avatarUrl: response.user.avatarUrl,
            isAdmin: response.user.isAdmin,
            isClubAdmin: response.user.isClubAdmin
        )
        isAuthenticated = true
    }

    func resetToClubSetup() {
        declinedClubName = nil
        needsClubSetup = true
        errorMessage = nil
    }

    func signOut() {
        TokenStore.shared.clear()
        isAuthenticated = false
        needsClubSetup = false
        pendingApprovalClubName = nil
        declinedClubName = nil
    }

    func deleteAccount() {
        isLoading = true
        errorMessage = nil
        Task {
            defer { isLoading = false }
            do {
                try await APIClient.shared.deleteMyAccount()
                signOut()
            } catch {
                errorMessage = "Failed to delete account. Please try again."
            }
        }
    }

    func demoLogin(passphrase: String) {
        isLoading = true
        errorMessage = nil
        Task {
            defer { isLoading = false }
            do {
                let response = try await APIClient.shared.demoLogin(passphrase: passphrase)
                finishSignIn(response)
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
                finishSignIn(response)
            } catch {
                errorMessage = "Dev login failed: \(error)"
            }
        }
    }
    #endif
}
