import SwiftUI

// A brief confirmation banner ("Saved to Photos", "Message bookmarked") that slides in at the
// top and clears itself. Owners hold a `Toast?` and attach `.toast($toast)`; setting a new value
// restarts the timer, so back-to-back confirmations don't cut each other short.
struct Toast: Equatable {
    let id = UUID()
    let text: String
    let systemImage: String
}

private struct ToastModifier: ViewModifier {
    @Binding var toast: Toast?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let toast {
                    Label(toast.text, systemImage: toast.systemImage)
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color.accentColor, in: Capsule())
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .accessibilityIdentifier("toast")
                }
            }
            .animation(.spring(duration: 0.3), value: toast)
            .task(id: toast?.id) {
                guard toast != nil else { return }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if !Task.isCancelled { toast = nil }
            }
    }
}

extension View {
    func toast(_ toast: Binding<Toast?>) -> some View {
        modifier(ToastModifier(toast: toast))
    }
}
