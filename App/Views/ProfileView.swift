import SwiftUI
import PhotosUI
import UIKit

struct ProfileView: View {
    @Binding var path: NavigationPath
    @EnvironmentObject var auth: AuthViewModel
    @StateObject private var viewModel = ProfileViewModel()
    @State private var showImageOptions = false
    @State private var showLibraryPicker = false
    @State private var showCamera = false
    @State private var photosItem: PhotosPickerItem?
    @State private var showJoinOrCreate = false

    var body: some View {
        NavigationStack(path: $path) {
            Form {
                Section {
                    HStack {
                        Spacer()
                        avatarView
                            .onTapGesture { showImageOptions = true }
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                    .padding(.vertical, 8)
                }

                Section("Name") {
                    TextField("Your name", text: $viewModel.displayName)
                        .autocorrectionDisabled()
                }

                Section {
                    TextField("Nickname (optional)", text: $viewModel.nickname)
                        .autocorrectionDisabled()
                } header: {
                    Text("Nickname")
                } footer: {
                    Text("If set, shown in chat instead of your name.")
                }

                Section {
                    Button {
                        Task { await viewModel.save() }
                    } label: {
                        if viewModel.isSaving {
                            ProgressView().frame(maxWidth: .infinity)
                        } else {
                            Text("Save Profile").frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(viewModel.isSaving)
                }

                Section {
                    NavigationLink("Blocked Users") {
                        BlockedUsersView()
                    }
                    Button("Join or Create Club") {
                        showJoinOrCreate = true
                    }
                }

                Section {
                    Button(role: .destructive) {
                        auth.signOut()
                    } label: {
                        Text("Sign Out").frame(maxWidth: .infinity)
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
                }
            }
            .navigationTitle("Profile")
            .task { await viewModel.loadAvatar() }
            .confirmationDialog("Change Photo", isPresented: $showImageOptions, titleVisibility: .visible) {
                Button("Choose from Library") { showLibraryPicker = true }
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    Button("Take Photo") { showCamera = true }
                }
                Button("Cancel", role: .cancel) {}
            }
            .photosPicker(isPresented: $showLibraryPicker, selection: $photosItem, matching: .images)
            .sheet(isPresented: $showCamera) {
                CameraPickerView(image: $viewModel.pendingImage)
            }
            .onChange(of: photosItem) { item in
                Task {
                    if let data = try? await item?.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        viewModel.pendingImage = image
                    }
                }
            }
            .alert("Error", isPresented: Binding(
                get: { viewModel.errorMessage != nil },
                set: { if !$0 { viewModel.errorMessage = nil } }
            )) {
                Button("OK") { viewModel.errorMessage = nil }
            } message: {
                Text(viewModel.errorMessage ?? "")
            }
            .alert("Saved", isPresented: $viewModel.saveSuccess) {
                Button("OK") {}
            } message: {
                Text("Your profile has been updated.")
            }
            .sheet(isPresented: $showJoinOrCreate) {
                JoinOrCreateClubView()
            }
        }
    }

    @ViewBuilder
    private var avatarView: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let image = viewModel.pendingImage ?? viewModel.displayImage ?? viewModel.loadedAvatarImage {
                    Image(uiImage: image)
                        .resizable().scaledToFill()
                } else {
                    avatarPlaceholder
                }
            }
            .frame(width: 96, height: 96)
            .clipShape(Circle())

            Circle()
                .fill(Color.accentColor)
                .frame(width: 28, height: 28)
                .overlay(
                    Image(systemName: "camera.fill")
                        .font(.system(size: 13))
                        .foregroundColor(.white)
                )
        }
    }

    private var avatarPlaceholder: some View {
        Circle()
            .fill(Color(.systemGray4))
            .overlay(
                Image(systemName: "person.fill")
                    .font(.system(size: 40))
                    .foregroundColor(.white)
            )
    }
}

struct CameraPickerView: UIViewControllerRepresentable {
    @Binding var image: UIImage?
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraDevice = .front
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPickerView
        init(_ parent: CameraPickerView) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            parent.image = info[.originalImage] as? UIImage
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

struct BlockedUsersView: View {
    @State private var blockedUsers: [APIClient.UserResponse] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if blockedUsers.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "hand.raised.slash")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                    Text("No blocked users")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(blockedUsers, id: \.id) { user in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(user.displayName).font(.headline)
                                if let nick = user.nickname {
                                    Text("\"\(nick)\"").font(.caption).foregroundColor(.secondary)
                                }
                            }
                            Spacer()
                        }
                        .swipeActions(edge: .trailing) {
                            Button {
                                Task { await unblock(user) }
                            } label: {
                                Label("Unblock", systemImage: "hand.raised.slash")
                            }
                            .tint(.blue)
                        }
                    }
                }
            }
        }
        .navigationTitle("Blocked Users")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Error", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            blockedUsers = try await APIClient.shared.fetchBlockedUsers()
        } catch {
            errorMessage = "Failed to load blocked users."
        }
    }

    private func unblock(_ user: APIClient.UserResponse) async {
        blockedUsers.removeAll { $0.id == user.id }
        do {
            try await APIClient.shared.unblockUser(userId: user.id)
        } catch {
            blockedUsers.append(user)
            errorMessage = "Failed to unblock user."
        }
    }
}

struct ProfileView_Previews: PreviewProvider {
    static var previews: some View {
        ProfileView(path: .constant(NavigationPath()))
            .environmentObject(AuthViewModel())
    }
}
