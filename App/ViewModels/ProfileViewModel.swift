import Foundation
import UIKit

@MainActor
final class ProfileViewModel: ObservableObject {
    @Published var displayName: String
    @Published var nickname: String
    @Published var avatarUrl: String?
    @Published var pendingImage: UIImage?
    @Published var displayImage: UIImage?
    @Published var isSaving = false
    @Published var loadedAvatarImage: UIImage?
    @Published var errorMessage: String?
    @Published var saveSuccess = false

    init() {
        displayName = TokenStore.shared.displayName ?? ""
        nickname = TokenStore.shared.nickname ?? ""
        avatarUrl = TokenStore.shared.avatarUrl
    }

    func loadAvatar() async {
        guard let user = try? await APIClient.shared.getMe() else { return }
        displayName = user.displayName
        nickname = user.nickname ?? ""
        avatarUrl = user.avatarUrl
        TokenStore.shared.displayName = user.displayName
        TokenStore.shared.nickname = user.nickname
        TokenStore.shared.avatarUrl = user.avatarUrl
        UserDefaults.standard.set(user.preferences.tapToTalk, forKey: "tapToTalkEnabled")

        guard let urlStr = user.avatarUrl, let url = URL(string: urlStr) else { return }
        if let cached = ImageCache.shared[url] { loadedAvatarImage = cached; return }
        let request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad)
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let img = UIImage(data: data) else { return }
        ImageCache.shared[url] = img
        loadedAvatarImage = img
    }

    func save() async {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            var finalAvatarUrl = avatarUrl
            if let image = pendingImage {
                let uploadResp = try await APIClient.shared.getAvatarUploadUrl()
                let data = image.resizedForUpload(maxDimension: 512).jpegData(compressionQuality: 0.8)!
                try await APIClient.shared.uploadMedia(
                    data: data,
                    to: URL(string: uploadResp.uploadUrl)!,
                    contentType: "image/jpeg"
                )
                // Append timestamp so AsyncImage treats each upload as a new URL,
                // bypassing any stale URLCache entry for the same blob path.
                let ts = Int(Date().timeIntervalSince1970)
                finalAvatarUrl = uploadResp.mediaUrl + "?t=\(ts)"
            }
            let trimmedName = displayName.trimmingCharacters(in: .whitespaces)
            let trimmedNick = nickname.trimmingCharacters(in: .whitespaces)
            let updated = try await APIClient.shared.updateProfile(
                displayName: trimmedName.isEmpty ? nil : trimmedName,
                nickname: trimmedNick.isEmpty ? nil : trimmedNick,
                avatarUrl: finalAvatarUrl
            )
            TokenStore.shared.displayName = updated.displayName
            TokenStore.shared.nickname = updated.nickname
            TokenStore.shared.avatarUrl = updated.avatarUrl
            displayName = updated.displayName
            avatarUrl = updated.avatarUrl
            displayImage = pendingImage
            pendingImage = nil
            saveSuccess = true
        } catch {
            errorMessage = "Save failed. Please try again."
        }
    }
}
