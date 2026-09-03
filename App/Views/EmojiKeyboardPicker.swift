import SwiftUI
import UIKit

// #145 — full emoji reaction picker, "+" on the reaction bar. Rather than building a custom
// emoji grid, this opens the real system Emoji keyboard (a well-established public-API
// technique: overriding textInputMode to prefer it) — closer to iOS Messages' own reaction
// picker than any custom grid would be, and far less code.

// Prefers the system Emoji keyboard as its input mode; falls back to the default keyboard if
// Emoji isn't in the user's enabled keyboard list (rare — it ships enabled by default).
private final class EmojiTextField: UITextField {
    override var textInputMode: UITextInputMode? {
        UITextInputMode.activeInputModes.first { $0.primaryLanguage == "emoji" } ?? super.textInputMode
    }
}

// Wraps EmojiTextField, becomes first responder immediately, and reports the first character
// typed (a full Character, not a Unicode scalar — multi-scalar emoji like skin-tone modifiers,
// ZWJ sequences, and flags are single Characters/grapheme clusters, and a scalar-level read
// would truncate them). The field never actually accepts the character — nothing is shown.
struct EmojiKeyboardPicker: UIViewRepresentable {
    let onPick: (Character) -> Void

    func makeUIView(context: Context) -> UITextField {
        let field = EmojiTextField(frame: .zero)
        field.delegate = context.coordinator
        field.tintColor = .clear
        DispatchQueue.main.async { field.becomeFirstResponder() }
        return field
    }

    func updateUIView(_ uiView: UITextField, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, UITextFieldDelegate {
        let onPick: (Character) -> Void
        init(onPick: @escaping (Character) -> Void) { self.onPick = onPick }

        func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
            if let first = string.first { onPick(first) }
            return false
        }
    }
}

// Small sheet hosting the picker — same .presentationDetents([.medium]) pattern already used
// elsewhere in BookDetailView.swift, rather than a less-common .height() detent.
struct EmojiPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onPick: (Character) -> Void

    var body: some View {
        VStack {
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .padding()
            }
            Spacer()
            EmojiKeyboardPicker { emoji in
                onPick(emoji)
                dismiss()
            }
            .frame(width: 0, height: 0)
            Spacer()
        }
        .presentationDetents([.medium])
    }
}
