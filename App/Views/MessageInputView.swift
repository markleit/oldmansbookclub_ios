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
    @State private var height: CGFloat = 36

    var body: some View {
        ZStack(alignment: .topLeading) {
            GrowingTextView(text: $text, height: $height)
                .frame(height: min(height, 120))

            if text.isEmpty {
                Text(placeholder)
                    .font(.body)
                    .foregroundColor(Color(.placeholderText))
                    .padding(.leading, 12)
                    .padding(.top, 8)
                    .allowsHitTesting(false)
            }
        }
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }
}

struct GrowingTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.font = UIFont.preferredFont(forTextStyle: .body)
        tv.textContainerInset = UIEdgeInsets(top: 8, left: 6, bottom: 8, right: 6)
        tv.textContainer.lineFragmentPadding = 0
        tv.isScrollEnabled = false
        tv.backgroundColor = .clear
        tv.delegate = context.coordinator
        tv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        if tv.text != text { tv.text = text }
        recalcHeight(tv)
    }

    func recalcHeight(_ tv: UITextView) {
        let size = tv.sizeThatFits(CGSize(width: tv.frame.width > 0 ? tv.frame.width : UIScreen.main.bounds.width, height: .infinity))
        let newHeight = max(size.height, 36)
        if abs(newHeight - height) > 0.5 {
            DispatchQueue.main.async { height = newHeight }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: GrowingTextView
        init(_ parent: GrowingTextView) { self.parent = parent }

        func textViewDidChange(_ tv: UITextView) {
            parent.text = tv.text
            parent.recalcHeight(tv)
        }
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
