import SwiftUI
import UIKit
import AVKit
import AVFoundation
import VisionKit

// MARK: - Full-screen photo

// Full-screen photo viewer, modeled on Messages (#191, #193, #201):
// - pinch zooms around the fingers, and a zoomed photo pans to every edge (the old SwiftUI
//   version only allowed dragging at 1×, so the sides of a zoomed photo were unreachable);
// - double-tap zooms in on that spot / back out; single tap hides or shows the controls;
// - swipe left/right pages through the chat's photos ("3 of 12") — at 1× only; zoomed, the
//   same swipe pans the photo, so zooming in never flips to another photo by accident;
// - pull down to close, but only when not zoomed, so it never fights panning;
// - Share opens the system sheet (Save Image, Copy, AirDrop…) on the current ORIGINAL file;
// - press-and-hold on the photo is Live Text / subject lift where the device supports it.
struct FullScreenImageView: View {
    let urls: [URL]
    @Environment(\.dismiss) private var dismiss
    @State private var index: Int
    @State private var chromeHidden = false
    @State private var preparingShare = false
    @State private var pullProgress: CGFloat = 0   // 0…1 while dragging the photo down to close

    init(url: URL) {
        self.init(urls: [url], startIndex: 0)
    }

    init(urls: [URL], startIndex: Int) {
        self.urls = urls
        _index = State(initialValue: min(max(0, startIndex), max(0, urls.count - 1)))
    }

    var body: some View {
        ZStack {
            // Fades as the photo is pulled down, revealing the chat underneath (Messages-style).
            Color.black.opacity(1 - pullProgress).ignoresSafeArea()
            TabView(selection: $index) {
                ForEach(urls.indices, id: \.self) { i in
                    PhotoPage(
                        url: urls[i],
                        isCurrent: i == index,
                        chromeHidden: chromeHidden,
                        onSingleTap: { withAnimation(.easeInOut(duration: 0.2)) { chromeHidden.toggle() } },
                        onPullProgress: { pullProgress = $0 },
                        onPullDismiss: { dismiss() }
                    )
                    .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()
        }
        .overlay(alignment: .top) {
            if !chromeHidden {
                ViewerTopBar(
                    shareEnabled: !urls.isEmpty,
                    preparingShare: preparingShare,
                    counter: urls.count > 1 ? "\(index + 1) of \(urls.count)" : nil,
                    onShare: share,
                    onClose: { dismiss() }
                )
                .opacity(1 - min(1, pullProgress * 3))
                .transition(.opacity)
            }
        }
        .presentationBackgroundClear()
        .statusBarHidden(chromeHidden)
    }

    // Share the original file so "Save Image" keeps full quality; fall back to the cached
    // decoded image if the download fails (e.g. offline).
    private func share() {
        guard !preparingShare, urls.indices.contains(index) else { return }
        let url = urls[index]
        preparingShare = true
        Task {
            var item: Any?
            if let file = try? await MediaDownloader.localFile(for: url, defaultExtension: "jpg") {
                item = file
            } else if let cached = await ImageCache.shared.get(url) {
                item = cached
            }
            preparingShare = false
            if let item { ShareSheet.present([item]) }
        }
    }
}

// One photo in the pager: loads (cache first) and hosts the zooming scroll view.
private struct PhotoPage: View {
    let url: URL
    let isCurrent: Bool
    let chromeHidden: Bool
    let onSingleTap: () -> Void
    let onPullProgress: (CGFloat) -> Void
    let onPullDismiss: () -> Void
    @State private var image: UIImage?
    @State private var loadFailed = false

    var body: some View {
        Group {
            if let image {
                ZoomableImageView(
                    image: image,
                    isCurrent: isCurrent,
                    chromeHidden: chromeHidden,
                    onSingleTap: onSingleTap,
                    onPullProgress: onPullProgress,
                    onPullDismiss: onPullDismiss
                )
            } else if loadFailed {
                Image(systemName: "photo")
                    .font(.system(size: 50))
                    .foregroundColor(.secondary)
            } else {
                ProgressView().tint(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .task(id: url) { await load() }
    }

    private func load() async {
        if url.isFileURL {
            image = UIImage(contentsOfFile: url.path)
            loadFailed = image == nil
            return
        }
        // The chat bubble already decoded this photo — open instantly from the cache.
        if let cached = await ImageCache.shared.get(url) { image = cached; return }
        let request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let decoded = UIImage(data: data) else {
            loadFailed = true
            return
        }
        ImageCache.shared[url] = decoded
        image = decoded
    }
}

// Close (top-right) and Share (top-left), white-on-translucent so they read over any photo.
private struct ViewerTopBar: View {
    let shareEnabled: Bool
    let preparingShare: Bool
    var counter: String? = nil   // "3 of 12" when paging through several photos
    let onShare: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack {
            Button(action: onShare) {
                ZStack {
                    Circle().fill(Color.black.opacity(0.5)).frame(width: 36, height: 36)
                    if preparingShare {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white)
                            .offset(y: -1)
                    }
                }
            }
            .disabled(!shareEnabled || preparingShare)
            .accessibilityLabel("Share")
            .accessibilityIdentifier("viewerShare")
            Spacer()
            if let counter {
                Text(counter)
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.black.opacity(0.5)))
                    .accessibilityIdentifier("photoCounter")
                Spacer()
            }
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.white, Color.black.opacity(0.5))
            }
            .accessibilityLabel("Close")
            .accessibilityIdentifier("viewerClose")
        }
        .padding()
    }
}

// MARK: - Zoomable image (UIScrollView)

// A UIScrollView does pinch-to-zoom, panning with momentum, and edge bounce the way every iOS
// photo viewer does; recreating that with SwiftUI gestures is what left #191 broken.
struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage
    var isCurrent: Bool = true
    var chromeHidden: Bool
    var onSingleTap: () -> Void
    var onPullProgress: (CGFloat) -> Void
    var onPullDismiss: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> ZoomingImageScrollView {
        let view = ZoomingImageScrollView(image: image)
        view.delegate = context.coordinator
        context.coordinator.view = view
        return view
    }

    func updateUIView(_ view: ZoomingImageScrollView, context: Context) {
        view.onSingleTap = onSingleTap
        view.onPullProgress = onPullProgress
        view.onPullDismiss = onPullDismiss
        if view.imageView.image !== image { view.setImage(image) }
        view.setLiveTextButtonHidden(chromeHidden)
        // Only the page on screen answers to "fullScreenImage" (UI tests query it), and a page
        // swiped away goes back to 1× so it isn't still zoomed when you swipe back to it.
        view.accessibilityIdentifier = isCurrent ? "fullScreenImage" : "fullScreenImageOffscreen"
        if !isCurrent, view.zoomScale > view.minimumZoomScale { view.setZoomScale(view.minimumZoomScale, animated: false) }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var view: ZoomingImageScrollView?

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { view?.imageView }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            view?.centerImage()
            view?.updateGestureModes()
            view?.updateAccessibilityValue()
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) { view?.updateAccessibilityValue() }
    }
}

final class ZoomingImageScrollView: UIScrollView {
    let imageView = UIImageView()
    var onSingleTap: () -> Void = {}
    var onPullProgress: (CGFloat) -> Void = { _ in }
    var onPullDismiss: () -> Void = {}
    private lazy var dismissPan = UIPanGestureRecognizer(target: self, action: #selector(handleDismissPan(_:)))
    private let dismissPanDelegate = DismissPanDelegate()
    private var laidOutBounds: CGSize = .zero
    private var analysis: ImageAnalysisInteraction?
    private var analysisTask: Task<Void, Never>?

    init(image: UIImage) {
        super.init(frame: .zero)
        backgroundColor = .clear
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        decelerationRate = .fast
        bouncesZoom = true
        minimumZoomScale = 1

        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        addSubview(imageView)

        isAccessibilityElement = true
        accessibilityTraits = .image
        accessibilityLabel = "Photo"
        accessibilityIdentifier = "fullScreenImage"

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
        let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap))
        singleTap.require(toFail: doubleTap)
        addGestureRecognizer(singleTap)
        // One finger only: a two-finger pinch that drifts downward must stay a pinch on a real
        // device (the simulator's synthetic pinch never drifts, so tests can't catch this).
        dismissPan.maximumNumberOfTouches = 1
        dismissPan.delegate = dismissPanDelegate
        addGestureRecognizer(dismissPan)
        updateGestureModes()

        setImage(image)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setImage(_ image: UIImage) {
        imageView.image = image
        laidOutBounds = .zero
        setNeedsLayout()
        startLiveText(for: image)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Refit only when the viewport changes (first layout, rotation) — not on every scroll.
        if bounds.size != laidOutBounds, bounds.width > 0, bounds.height > 0 {
            laidOutBounds = bounds.size
            fitImage()
        }
    }

    // Aspect-fit the image at zoom 1, with enough maximum zoom to read fine print in a
    // full-resolution phone photo.
    private func fitImage() {
        guard let image = imageView.image, image.size.width > 0, image.size.height > 0 else { return }
        zoomScale = 1
        let fit = min(bounds.width / image.size.width, bounds.height / image.size.height)
        let size = CGSize(width: image.size.width * fit, height: image.size.height * fit)
        imageView.frame = CGRect(origin: .zero, size: size)
        contentSize = size
        // 1/fit is 1 image pixel per screen point; go at least 4×, never absurdly far.
        maximumZoomScale = min(max(4, 1 / fit), 12)
        centerImage()
        contentOffset = CGPoint(x: -contentInset.left, y: -contentInset.top)
        updateGestureModes()
        updateAccessibilityValue()
    }

    // Keep the image centered while it's smaller than the screen in either direction.
    func centerImage() {
        let insetX = max(0, (bounds.width - imageView.frame.width) / 2)
        let insetY = max(0, (bounds.height - imageView.frame.height) / 2)
        let inset = UIEdgeInsets(top: insetY, left: insetX, bottom: insetY, right: insetX)
        if contentInset != inset { contentInset = inset }
    }

    // "zoom=2.00 visible=0.00-0.50": the zoom level and the horizontal slice of the photo on
    // screen (0 = left edge, 1 = right edge). Lets UI tests prove a zoomed photo pans edge to
    // edge (#191); VoiceOver reads it too, which is harmless.
    func updateAccessibilityValue() {
        guard imageView.bounds.width > 0 else { return }
        let visible = convert(bounds, to: imageView).intersection(imageView.bounds)
        let from = max(0, visible.minX / imageView.bounds.width)
        let to = min(1, visible.maxX / imageView.bounds.width)
        accessibilityValue = String(format: "zoom=%.2f visible=%.2f-%.2f", zoomScale, from, to)
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        if zoomScale > minimumZoomScale + 0.01 {
            setZoomScale(minimumZoomScale, animated: true)
            return
        }
        let point = gesture.location(in: imageView)
        let scale = min(maximumZoomScale, 3)
        let size = CGSize(width: bounds.width / scale, height: bounds.height / scale)
        zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                        width: size.width, height: size.height), animated: true)
    }

    @objc private func handleSingleTap() { onSingleTap() }

    // MARK: Pull down to close

    // A drag means one thing at a time: at 1× it's pull-to-close (there's nothing to scroll),
    // zoomed it's panning. Never both, so panning a zoomed photo can't close it.
    func updateGestureModes() {
        let atFit = zoomScale <= minimumZoomScale + 0.01
        isScrollEnabled = !atFit
        dismissPan.isEnabled = atFit
        // #201 — zoomed, the photo pager stands still: panning to the edge of a zoomed photo
        // (reading the side of a list) must not flip to the next photo. Zoom out to page again.
        pagingAncestor?.isScrollEnabled = atFit
    }

    // The photo pager's scroll view (SwiftUI's page-style TabView), if this page is inside one.
    private var pagingAncestor: UIScrollView? {
        var view = superview
        while let current = view {
            if let scroll = current as? UIScrollView, scroll.isPagingEnabled { return scroll }
            view = current.superview
        }
        return nil
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { updateGestureModes() }
    }


    // The photo follows the finger; past a distance or a flick, close — otherwise spring back.
    // (A translation transform on the zooming view is safe here: this only runs at 1×.)
    @objc private func handleDismissPan(_ gesture: UIPanGestureRecognizer) {
        let t = gesture.translation(in: self)
        switch gesture.state {
        case .changed:
            imageView.transform = CGAffineTransform(translationX: t.x, y: max(0, t.y))
            onPullProgress(min(1, max(0, t.y / 400)))
        case .ended, .cancelled, .failed:
            let velocity = gesture.velocity(in: self).y
            if gesture.state == .ended && (t.y > 120 || velocity > 800) {
                onPullDismiss()
            } else {
                UIView.animate(withDuration: 0.25, delay: 0, usingSpringWithDamping: 0.85,
                               initialSpringVelocity: 0) {
                    self.imageView.transform = .identity
                }
                onPullProgress(0)
            }
        default:
            break
        }
    }

    // MARK: Live Text

    // Press-and-hold to select text / lift the subject, as in Photos and Messages. Silently
    // absent on devices (and simulators) without the Neural Engine support it needs.
    private func startLiveText(for image: UIImage) {
        analysisTask?.cancel()
        guard ImageAnalyzer.isSupported else { return }
        if analysis == nil {
            let interaction = ImageAnalysisInteraction()
            interaction.preferredInteractionTypes = .automatic
            imageView.addInteraction(interaction)
            analysis = interaction
        }
        analysis?.analysis = nil
        analysisTask = Task { @MainActor [weak self] in
            let config = ImageAnalyzer.Configuration([.text, .machineReadableCode, .visualLookUp])
            guard let result = try? await ImageAnalyzer().analyze(image, configuration: config),
                  !Task.isCancelled else { return }
            self?.analysis?.analysis = result
        }
    }

    func setLiveTextButtonHidden(_ hidden: Bool) {
        analysis?.setSupplementaryInterfaceHidden(hidden, animated: true)
    }
}

extension View {
    // Lets the chat show through a fullScreenCover as its own background fades (iOS 16.4+);
    // earlier systems keep the opaque default, which only loses the see-through effect.
    @ViewBuilder func presentationBackgroundClear() -> some View {
        if #available(iOS 16.4, *) {
            self.presentationBackground(.clear)
        } else {
            self
        }
    }
}

// Pull-to-close starts only on a downward drag, and tracks ALONGSIDE other gestures instead of
// competing with them: as a plain competing pan on every page it swallowed the photo pager's
// sideways swipe (#201), even though it then declined to begin. Its own delegate object, because
// the scroll view is already the delegate of its pan/pinch and must keep its default behavior.
private final class DismissPanDelegate: NSObject, UIGestureRecognizerDelegate {
    func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        guard let pan = gesture as? UIPanGestureRecognizer else { return true }
        let v = pan.velocity(in: pan.view)
        return v.y > abs(v.x)   // downward only
    }

    func gestureRecognizer(_ gesture: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}

// MARK: - Full-screen video

struct FullScreenVideoView: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var preparingShare = false

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            if let player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
            }
            ViewerTopBar(
                shareEnabled: true,
                preparingShare: preparingShare,
                onShare: share,
                onClose: {
                    player?.pause()
                    dismiss()
                }
            )
        }
        .onAppear {
            // Finalize-and-send any in-progress recording before claiming AVAudioSession for
            // playback — the two silently fight over the shared session otherwise (#160).
            AudioRecorder.forceStopForPlayback?()
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [])
            try? AVAudioSession.sharedInstance().setActive(true)
            let p = AVPlayer(url: url)
            player = p
            p.play()
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }

    // The share sheet only offers "Save Video" for a local file, so download first.
    private func share() {
        guard !preparingShare else { return }
        preparingShare = true
        Task {
            let file = try? await MediaDownloader.localFile(for: url, defaultExtension: "mp4")
            preparingShare = false
            if let file { ShareSheet.present([file]) }
        }
    }
}
