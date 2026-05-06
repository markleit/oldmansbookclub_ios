import SwiftUI
import PhotosUI
import UIKit

struct ProfileView: View {
    @EnvironmentObject var auth: AuthViewModel
    @StateObject private var viewModel = ProfileViewModel()
    @State private var showImageOptions = false
    @State private var showLibraryPicker = false
    @State private var showCamera = false
    @State private var photosItem: PhotosPickerItem?

    private var displayName: String {
        TokenStore.shared.displayName ?? "Book Club Member"
    }

    var body: some View {
        NavigationStack {
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

                Section("Display Name") {
                    Text(displayName)
                        .foregroundColor(.secondary)
                }

                Section("Nickname") {
                    TextField("Optional — shown in chat instead of display name", text: $viewModel.nickname)
                        .autocorrectionDisabled()
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
                    Button(role: .destructive) {
                        auth.signOut()
                    } label: {
                        Text("Sign Out").frame(maxWidth: .infinity)
                    }
                }
            }
            .navigationTitle("Profile")
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
        }
    }

    @ViewBuilder
    private var avatarView: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let image = viewModel.pendingImage {
                    Image(uiImage: image)
                        .resizable().scaledToFill()
                } else if let urlStr = viewModel.avatarUrl, let url = URL(string: urlStr) {
                    AsyncImage(url: url) { phase in
                        if let img = phase.image {
                            img.resizable().scaledToFill()
                        } else {
                            avatarPlaceholder
                        }
                    }
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

struct ProfileView_Previews: PreviewProvider {
    static var previews: some View {
        ProfileView()
            .environmentObject(AuthViewModel())
    }
}
