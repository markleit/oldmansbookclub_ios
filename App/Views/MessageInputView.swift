import SwiftUI
import PhotosUI
import AVFoundation
import UniformTypeIdentifiers

struct MessageInputView: View {
    @Binding var text: String
    @Binding var pendingImage: UIImage?
    @Binding var pendingVideo: URL?
    var isRecording: Bool
    var isUploading: Bool
    var isOffline: Bool = false
    var tapToTalk: Bool = false
    var onSend: () -> Void
    var onSendPhoto: () -> Void
    var onSendVideo: () -> Void
    var onToggleRecording: () -> Void
    var onStartRecording: () -> Void = {}
    var onStopRecording: () -> Void = {}
    var onShowSaved: () -> Void

    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var showingCamera = false
    @State private var showingPhotoPicker = false
    @State private var pulsing = false
    @State private var elapsedSeconds = 0

    private var hasContent: Bool {
        !text.trimmingCharacters(in: .whitespaces).isEmpty || pendingImage != nil || pendingVideo != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider()

            if isOffline {
                Label("You're offline — messages are read-only", systemImage: "wifi.slash")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color(.systemGray6))
            } else {
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

                // Pending video thumbnail
                if let videoUrl = pendingVideo {
                    HStack {
                        VideoThumbnailView(url: videoUrl)
                            .frame(width: 64, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay {
                                Image(systemName: "play.circle.fill")
                                    .font(.system(size: 24))
                                    .foregroundStyle(.white, .black.opacity(0.5))
                            }
                            .overlay(alignment: .topTrailing) {
                                Button {
                                    pendingVideo = nil
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

                    // + menu: photo library, camera, saved messages
                    Menu {
                        Button {
                            showingPhotoPicker = true
                        } label: {
                            Label("Photo Library", systemImage: "photo")
                        }
                        Button {
                            showingCamera = true
                        } label: {
                            Label("Camera", systemImage: "camera")
                        }
                        Button {
                            onShowSaved()
                        } label: {
                            Label("Saved Messages", systemImage: "bookmark")
                        }
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 28))
                            .foregroundColor(.secondary)
                            .frame(width: 44, height: 44)
                    }
                    .photosPicker(isPresented: $showingPhotoPicker, selection: $selectedPhotoItem, matching: .any(of: [.images, .videos]))
                    .onChange(of: selectedPhotoItem) { item in
                        Task {
                            guard let item else { return }
                            if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) || $0.conforms(to: .video) }) {
                                if let video = try? await item.loadTransferable(type: VideoTransferable.self) {
                                    pendingVideo = video.url
                                    pendingImage = nil
                                }
                            } else if let data = try? await item.loadTransferable(type: Data.self),
                                      let image = UIImage(data: data) {
                                pendingImage = image
                                pendingVideo = nil
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
                            if pendingVideo != nil {
                                onSendVideo()
                            } else if pendingImage != nil {
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
                        micButton
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
        }
        .fullScreenCover(isPresented: $showingCamera) {
            CameraView { image in
                pendingImage = image
                pendingVideo = nil
                showingCamera = false
            } onCaptureVideo: { url in
                pendingVideo = url
                pendingImage = nil
                showingCamera = false
            } onCancel: {
                showingCamera = false
            }
            .ignoresSafeArea()
        }
    }

    private var micIcon: some View {
        Image(systemName: "mic.fill")
            .font(.system(size: 28, weight: .semibold))
            .foregroundColor(isRecording ? .red : .accentColor)
            .frame(width: 44, height: 44)
            .overlay {
                if isRecording {
                    ZStack {
                        Circle()
                            .stroke(Color.red.opacity(0.5), lineWidth: 1.5)
                            .scaleEffect(pulsing ? 2.2 : 1.0)
                            .opacity(pulsing ? 0 : 0.6)
                            .animation(.easeOut(duration: 1.2).repeatForever(autoreverses: false), value: pulsing)
                        Circle()
                            .stroke(Color.red.opacity(0.5), lineWidth: 1.5)
                            .scaleEffect(pulsing ? 2.2 : 1.0)
                            .opacity(pulsing ? 0 : 0.6)
                            .animation(.easeOut(duration: 1.2).repeatForever(autoreverses: false).delay(0.45), value: pulsing)
                    }
                }
            }
            .overlay(alignment: .bottom) {
                if isRecording {
                    Text(formatElapsed(elapsedSeconds))
                        .font(.system(size: 10, weight: .semibold))
                        .monospacedDigit()
                        .foregroundColor(.red)
                        .fixedSize()
                        .offset(y: 14)
                }
            }
    }

    @ViewBuilder
    private var micButton: some View {
        if tapToTalk {
            Button { onToggleRecording() } label: { micIcon }
                .task(id: isRecording) { await runPulseTimer() }
        } else {
            micIcon
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in if !isRecording { onStartRecording() } }
                        .onEnded { _ in if isRecording { onStopRecording() } }
                )
                .task(id: isRecording) { await runPulseTimer() }
        }
    }

    private func runPulseTimer() async {
        elapsedSeconds = 0
        pulsing = false
        guard isRecording else { return }
        try? await Task.sleep(for: .milliseconds(50))
        guard !Task.isCancelled else { return }
        pulsing = true
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { break }
            elapsedSeconds += 1
        }
    }

    private func formatElapsed(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
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
        let newHeight = max(size.height, 44)
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
    var onCaptureVideo: (URL) -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = ["public.image", "public.movie"]
        picker.videoQuality = .typeHigh
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
            } else if let url = info[.mediaURL] as? URL {
                parent.onCaptureVideo(url)
            } else {
                parent.onCancel()
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.onCancel()
        }
    }
}

// MARK: - Video Transferable

struct VideoTransferable: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { video in
            SentTransferredFile(video.url)
        } importing: { received in
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("mp4")
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: received.file, to: dest)
            return VideoTransferable(url: dest)
        }
    }
}

// MARK: - Video Thumbnail

struct VideoThumbnailView: View {
    let url: URL
    @State private var thumbnail: UIImage?

    var body: some View {
        Group {
            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
            } else {
                Color(.systemGray4)
            }
        }
        .task {
            let asset = AVAsset(url: url)
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            if let cgImage = try? gen.copyCGImage(at: .zero, actualTime: nil) {
                thumbnail = UIImage(cgImage: cgImage)
            }
        }
    }
}
