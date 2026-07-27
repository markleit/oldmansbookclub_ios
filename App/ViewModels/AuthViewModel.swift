import AuthenticationServices
import Foundation

@MainActor
final class AuthViewModel: ObservableObject {
    @Published var isAuthenticated: Bool {
        didSet {
            // Broadcast sign-in/sign-out so out-of-SwiftUI surfaces can react — notably CarPlay
            // (#59), which observes this to reload its root when you sign in/out on the phone
            // while the car is connected. didSet doesn't fire for the init assignments, only
            // real transitions (signIn/signOut/onUnauthorized).
            guard oldValue != isAuthenticated else { return }
            NotificationCenter.default.post(name: .authStateDidChange, object: nil)
        }
    }
    @Published var needsClubSetup = false
    @Published var pendingApprovalClubName: String?
    @Published var declinedClubName: String?
    @Published var isLoading = false
    @Published var errorMessage: String?

    private var pendingIdentityToken: String?
    private var pendingDisplayName: String?
    private var pendingEmail: String?

    init() {
        // A session is valid as long as a refresh token exists — the short-lived (1h)
        // access token being expired on launch is normal and recoverable via
        // /auth/refresh. Previously a cold launch with an expired access token cleared
        // BOTH tokens and forced a re-login, never using the still-valid 90-day refresh
        // token: the #1 cause of "asked to sign in again after idle". Stay authenticated
        // and refresh in the background; only a hard rejection (or no refresh token at
        // all) signs the user out.
        if TokenStore.shared.refreshToken != nil {
            isAuthenticated = TokenStore.shared.isAuthenticated
            Task { @MainActor [weak self] in
                let ok = await APIClient.shared.ensureFreshToken()
                if !ok { self?.signOut() }
            }
        } else if TokenStore.shared.isTokenExpired {
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
            refreshToken: response.refreshToken,
            userId: response.user.id,
            displayName: response.user.displayName,
            nickname: response.user.nickname,
            avatarUrl: response.user.avatarUrl,
            isAdmin: response.user.isAdmin,
            isClubAdmin: response.user.isClubAdmin
        )
        UserDefaults.standard.set(response.user.preferences.tapToTalk, forKey: "tapToTalkEnabled")
        isAuthenticated = true
    }

    func resetToClubSetup() {
        declinedClubName = nil
        needsClubSetup = true
        errorMessage = nil
    }

    func signOut() {
        // Fire-and-forget revoke; we don't block sign-out on the round trip.
        if let rt = TokenStore.shared.refreshToken {
            Task { try? await APIClient.shared.logout(refreshToken: rt) }
        }
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

extension Notification.Name {
    // Posted when the signed-in/signed-out state changes (see AuthViewModel.isAuthenticated).
    static let authStateDidChange = Notification.Name("authStateDidChange")
}
