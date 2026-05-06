import Foundation
import UIKit

@MainActor
final class ProfileViewModel: ObservableObject {
    @Published var nickname: String
    @Published var avatarUrl: String?
    @Published var pendingImage: UIImage?
    @Published var isSaving = false
    @Published var errorMessage: String?
    @Published var saveSuccess = false

    init() {
        nickname = TokenStore.shared.nickname ?? ""
        avatarUrl = TokenStore.shared.avatarUrl
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
                finalAvatarUrl = uploadResp.mediaUrl
            }
            let trimmed = nickname.trimmingCharacters(in: .whitespaces)
            let nicknameToSend = trimmed.isEmpty ? nil : trimmed
            let updated = try await APIClient.shared.updateProfile(
                nickname: nicknameToSend,
                avatarUrl: finalAvatarUrl
            )
            TokenStore.shared.nickname = updated.nickname
            TokenStore.shared.avatarUrl = updated.avatarUrl
            avatarUrl = updated.avatarUrl
            pendingImage = nil
            saveSuccess = true
        } catch {
            errorMessage = "Save failed. Please try again."
        }
    }
}
