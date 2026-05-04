import SwiftUI
import PhotosUI

struct MessageInputView: View {
    @Binding var text: String
    @Binding var pendingImage: UIImage?
    var isRecording: Bool
    var isUploading: Bool
    var onSend: () -> Void
    var onSendPhoto: () -> Void
    var onToggleRecording: () -> Void

    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var showingCamera = false

    private var hasContent: Bool {
        !text.trimmingCharacters(in: .whitespaces).isEmpty || pendingImage != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider()

            // Pending image thumbnail
            if let image = pendingImage {
                HStack {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(alignment: .topTrailing) {
                            Button {
                                pendingImage = nil
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.white, .black)
                                    .font(.title3)
                            }
                            .offset(x: 6, y: -6)
                        }
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.top, 8)
            }

            HStack(alignment: .bottom, spacing: 8) {

                // Camera
                Button {
                    showingCamera = true
                } label: {
                    Image(systemName: "camera.fill")
                        .font(.title3)
                        .foregroundColor(.secondary)
                }

                // Photo picker
                PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                        .foregroundColor(.secondary)
                }
                .onChange(of: selectedPhotoItem) { item in
                    Task {
                        if let data = try? await item?.loadTransferable(type: Data.self),
                           let image = UIImage(data: data) {
                            pendingImage = image
                        }
                        selectedPhotoItem = nil
                    }
                }

                // Growing text input
                GrowingTextEditor(text: $text, placeholder: "Message…")

                // Walkie-talkie / send button
                if isUploading {
                    ProgressView()
                        .frame(width: 32, height: 32)
                } else if hasContent {
                    Button {
                        if pendingImage != nil {
                            onSendPhoto()
                        } else {
                            onSend()
                        }
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundColor(.accentColor)
                            .frame(width: 44, height: 44)
                    }
                } else {
                    Button {
                        onToggleRecording()
                    } label: {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundColor(isRecording ? .red : .accentColor)
                            .frame(width: 44, height: 44)
                            .scaleEffect(isRecording ? 1.15 : 1.0)
                            .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true),
                                       value: isRecording)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .fullScreenCover(isPresented: $showingCamera) {
            CameraView { image in
                pendingImage = image
                showingCamera = false
            } onCancel: {
                showingCamera = false
            }
            .ignoresSafeArea()
        }
    }
}

// MARK: - Growing TextEditor

struct GrowingTextEditor: View {
    @Binding var text: String
    let placeholder: String

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Invisible replica drives height: starts single-line, grows up to 5 lines
            Text(text.isEmpty ? " " : text)
                .font(.body)
                .lineLimit(5)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .opacity(0)

            if text.isEmpty {
                Text(placeholder)
                    .font(.body)
                    .foregroundColor(Color(.placeholderText))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .allowsHitTesting(false)
            }

            TextEditor(text: $text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 8)
                .padding(.vertical, 0)
        }
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }
}

// MARK: - Camera

struct CameraView: UIViewControllerRepresentable {
    var onCapture: (UIImage) -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = ["public.image"]
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraView
        init(_ parent: CameraView) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage {
                parent.onCapture(image)
            } else {
                parent.onCancel()
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.onCancel()
        }
    }
}
