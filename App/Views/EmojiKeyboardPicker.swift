import SwiftUI

// #145 — full emoji reaction picker, "+" on the reaction bar.
//
// Two earlier approaches to this were tried and abandoned:
// 1. Forcing the system Emoji keyboard open directly (overriding UITextField.textInputMode on
//    an invisible field) — proved unstable on-device: live console logging confirmed the OS
//    periodically resigns and rebuilds the input view (~every 0.5s), visible as continuous
//    repainting. iOS actively distrusting an input view whose typed characters are always
//    rejected while forced into a non-default keyboard isn't something patchable further.
// 2. A visible field + manual globe-key keyboard switch — mechanically stable, but disliked:
//    it's not how any of the apps this feature is meant to match (Messages, WhatsApp, Messenger)
//    actually do it. None of them borrow or force the system keyboard for reactions — they all
//    built their own curated emoji grid. This is that: no system keyboard involved at all, so
//    no fighting the OS, and it's the standard approach for exactly this feature.
struct EmojiPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onPick: (Character) -> Void

    @State private var selectedCategory = EmojiCategory.allCases.first!
    // #173 — per-emoji remembered tones, and which emoji's tone popup (if any) is open.
    @State private var tones = EmojiSkinTone.rememberedTones()
    @State private var toneChooserFor: String?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 8)

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Reaction").font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }
            }
            .padding()

            categoryPicker

            ScrollView {
                LazyVGrid(columns: columns, spacing: 4) {
                    ForEach(selectedCategory.emoji, id: \.self) { base in
                        emojiCell(base)
                    }
                }
                .padding(.horizontal, 8)
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var categoryPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(EmojiCategory.allCases) { category in
                    Button {
                        selectedCategory = category
                    } label: {
                        Text(category.icon)
                            .font(.system(size: 22))
                            .frame(width: 40, height: 36)
                            .background(
                                selectedCategory == category ? Color(.systemGray4) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 8)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
        }
        .padding(.bottom, 8)
    }

    private func tone(for base: String) -> EmojiSkinTone { tones[base] ?? .none }

    private func pick(_ emoji: String) {
        toneChooserFor = nil
        if let char = emoji.first { onPick(char) }
        dismiss()
    }

    // #173 — same model as the iOS emoji keyboard: a tap sends the emoji in its remembered tone;
    // press-and-hold on an emoji that takes a tone opens the six variants, and the one chosen is
    // remembered for that emoji only. Emoji that don't take a tone ignore the hold.
    private func emojiCell(_ base: String) -> some View {
        let tonable = EmojiSkinTone.canTone(base)
        return Button {
            pick(tone(for: base).apply(to: base))
        } label: {
            Text(tone(for: base).apply(to: base))
                .font(.system(size: 30))
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("emoji.\(base)")
        // highPriority so a completed hold suppresses the Button's tap-on-release (as in #47);
        // masked off entirely for emoji without tones, so their taps are untouched.
        .highPriorityGesture(
            LongPressGesture(minimumDuration: 0.35).onEnded { _ in
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                toneChooserFor = base
            },
            including: tonable ? .all : .subviews
        )
        .accessibilityActions {
            if tonable {
                Button("Skin tones") { toneChooserFor = base }
            }
        }
        .popover(isPresented: Binding(
            get: { toneChooserFor == base },
            set: { if !$0 { toneChooserFor = nil } }
        )) {
            toneChooser(for: base)
        }
    }

    private func toneChooser(for base: String) -> some View {
        HStack(spacing: 2) {
            ForEach(EmojiSkinTone.allCases) { option in
                Button {
                    EmojiSkinTone.remember(option, for: base)
                    tones[base] = option
                    pick(option.apply(to: base))
                } label: {
                    Text(option.apply(to: base))
                        .font(.system(size: 30))
                        .frame(width: 44, height: 44)
                        .background(
                            tone(for: base) == option ? Color(.systemGray4) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option.accessibilityName)
                .accessibilityAddTraits(tone(for: base) == option ? .isSelected : [])
                .accessibilityIdentifier("skinTone.\(option.rawValue)")
            }
        }
        .padding(6)
        .popoverCompactAdaptation()
    }
}

// #173 — Fitzpatrick skin-tone modifiers. Which emoji accept one comes from Unicode's own
// Emoji_Modifier_Base property rather than a hand-maintained list, so the curated set below can
// grow without this needing to know about it.
enum EmojiSkinTone: Int, CaseIterable, Identifiable {
    case none, light, mediumLight, medium, mediumDark, dark

    // Per-emoji memory, like the system keyboard: [untoned emoji: rawValue]. Device-local.
    private static let storageKey = "emojiSkinTones"

    static func rememberedTones() -> [String: EmojiSkinTone] {
        let raw = UserDefaults.standard.dictionary(forKey: storageKey) as? [String: Int] ?? [:]
        return raw.compactMapValues(EmojiSkinTone.init(rawValue:))
    }

    static func remembered(for emoji: String) -> EmojiSkinTone {
        rememberedTones()[emoji] ?? .none
    }

    static func remember(_ tone: EmojiSkinTone, for emoji: String) {
        var raw = UserDefaults.standard.dictionary(forKey: storageKey) as? [String: Int] ?? [:]
        raw[emoji] = tone == .none ? nil : tone.rawValue
        UserDefaults.standard.set(raw, forKey: storageKey)
    }

    static func canTone(_ emoji: String) -> Bool {
        EmojiSkinTone.dark.apply(to: emoji) != emoji
    }

    // Modifier bases that the Unicode data still flags but the RGI set (what iOS actually draws
    // as one glyph) dropped toned forms for — iOS would render the base plus a loose color swatch.
    private static let excludedBases: Set<Unicode.Scalar> = ["\u{1F93C}"]   // 🤼

    var id: Int { rawValue }

    private var modifier: Unicode.Scalar? {
        switch self {
        case .none: return nil
        case .light: return "\u{1F3FB}"
        case .mediumLight: return "\u{1F3FC}"
        case .medium: return "\u{1F3FD}"
        case .mediumDark: return "\u{1F3FE}"
        case .dark: return "\u{1F3FF}"
        }
    }

    var accessibilityName: String {
        switch self {
        case .none: return "Default skin tone"
        case .light: return "Light skin tone"
        case .mediumLight: return "Medium-light skin tone"
        case .medium: return "Medium skin tone"
        case .mediumDark: return "Medium-dark skin tone"
        case .dark: return "Dark skin tone"
        }
    }

    /// The toned form of `emoji`, or `emoji` unchanged if it doesn't take a tone (or the tone is
    /// `.none`). The modifier goes right after the base and replaces any variation selector
    /// (☝️ → ☝🏽), which keeps ZWJ suffixes like 🕵️‍♂️ → 🕵🏽‍♂️ intact.
    func apply(to emoji: String) -> String {
        guard let modifier else { return emoji }
        var scalars = Array(emoji.unicodeScalars)
        guard let base = scalars.first, base.properties.isEmojiModifierBase,
              !Self.excludedBases.contains(base),
              // Multi-person sequences (👫, 🧑‍🤝‍🧑) take a tone per person — out of scope here.
              !scalars.dropFirst().contains(where: { $0.properties.isEmojiModifierBase })
        else { return emoji }
        scalars.removeFirst()
        if scalars.first == "\u{FE0F}" { scalars.removeFirst() }
        var toned = String.UnicodeScalarView()
        toned.append(base)
        toned.append(modifier)
        toned.append(contentsOf: scalars)
        return String(toned)
    }
}

// A curated, static emoji set grouped into the same broad categories the system emoji keyboard
// uses. There's no public API to enumerate emoji at runtime — every app with a custom emoji
// picker (this one included) hardcodes a data set like this one.
private enum EmojiCategory: String, CaseIterable, Identifiable {
    case smileys, people, animals, food, activities, travel, objects, symbols, flags

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .smileys: return "😀"
        case .people: return "👋"
        case .animals: return "🐶"
        case .food: return "🍔"
        case .activities: return "⚽️"
        case .travel: return "✈️"
        case .objects: return "💡"
        case .symbols: return "❤️"
        case .flags: return "🏳️"
        }
    }

    var emoji: [String] {
        switch self {
        case .smileys:
            return ["😀", "😃", "😄", "😁", "😆", "😅", "🤣", "😂", "🙂", "🙃",
                    "😉", "😊", "😇", "🥰", "😍", "🤩", "😘", "😗", "😚", "😙",
                    "😋", "😛", "😜", "🤪", "😝", "🤑", "🤗", "🤭", "🤫", "🤔",
                    "🤐", "🤨", "😐", "😑", "😶", "😏", "😒", "🙄", "😬", "🤥",
                    "😌", "😔", "😪", "🤤", "😴", "😷", "🤒", "🤕", "🤢", "🤮",
                    "🤧", "🥵", "🥶", "🥴", "😵", "🤯", "🤠", "🥳", "😎", "🤓",
                    "🧐", "😕", "😟", "🙁", "😮", "😯", "😲", "😳", "🥺", "😦",
                    "😧", "😨", "😰", "😥", "😢", "😭", "😱", "😖", "😣", "😞",
                    "😓", "😩", "😫", "🥱", "😤", "😡", "😠", "🤬", "😈", "👿"]
        case .people:
            return ["👋", "🤚", "🖐", "✋", "🖖", "👌", "🤌", "🤏", "✌️", "🤞",
                    "🤟", "🤘", "🤙", "👈", "👉", "👆", "🖕", "👇", "☝️", "👍",
                    "👎", "✊", "👊", "🤛", "🤜", "👏", "🙌", "👐", "🤲", "🙏",
                    "💪", "🦾", "🫶", "👶", "🧒", "👦", "👧", "🧑", "👱", "👨",
                    "🧔", "👩", "🧓", "👴", "👵", "🙍", "🙎", "🙅", "🙆", "💁",
                    "🙋", "🧏", "🙇", "🤦", "🤷", "👮", "🕵️", "💂", "👷", "🤴",
                    "👸", "👳", "👲", "🧕", "🤵", "👰", "🤰", "🤱", "👼", "🎅",
                    "🤶", "🦸", "🦹", "🧙", "🧚", "🧛", "🧜", "🧝", "🧞", "🧟"]
        case .animals:
            return ["🐶", "🐱", "🐭", "🐹", "🐰", "🦊", "🐻", "🐼", "🐻‍❄️", "🐨",
                    "🐯", "🦁", "🐮", "🐷", "🐽", "🐸", "🐵", "🙈", "🙉", "🙊",
                    "🐒", "🐔", "🐧", "🐦", "🐤", "🐣", "🐥", "🦆", "🦅", "🦉",
                    "🦇", "🐺", "🐗", "🐴", "🦄", "🐝", "🪱", "🐛", "🦋", "🐌",
                    "🐞", "🐜", "🦟", "🦗", "🕷", "🕸", "🐢", "🐍", "🦎", "🦖",
                    "🦕", "🐙", "🦑", "🦐", "🦞", "🦀", "🐡", "🐠", "🐟", "🐬",
                    "🐳", "🐋", "🦈", "🐊", "🐅", "🐆", "🦓", "🦍", "🦧", "🐘",
                    "🦛", "🦏", "🐪", "🐫", "🦒", "🦘", "🐃", "🐂", "🐄", "🐎"]
        case .food:
            return ["🍏", "🍎", "🍐", "🍊", "🍋", "🍌", "🍉", "🍇", "🍓", "🫐",
                    "🍈", "🍒", "🍑", "🥭", "🍍", "🥥", "🥝", "🍅", "🍆", "🥑",
                    "🥦", "🥬", "🥒", "🌶", "🫑", "🌽", "🥕", "🫒", "🧄", "🧅",
                    "🥔", "🍠", "🥐", "🥯", "🍞", "🥖", "🥨", "🧀", "🥚", "🍳",
                    "🧈", "🥞", "🧇", "🥓", "🥩", "🍗", "🍖", "🌭", "🍔", "🍟",
                    "🍕", "🫓", "🥪", "🥙", "🧆", "🌮", "🌯", "🫔", "🥗", "🥘",
                    "🍝", "🍜", "🍲", "🍛", "🍣", "🍱", "🥟", "🦪", "🍤", "🍙",
                    "🍚", "🍘", "🍥", "🥠", "🍢", "🍡", "🍧", "🍨", "🍦", "🥧",
                    "🧁", "🍰", "🎂", "🍮", "🍭", "🍬", "🍫", "🍿", "🍩", "🍪",
                    "☕️", "🍵", "🧃", "🥤", "🧋", "🍺", "🍻", "🥂", "🍷", "🥃"]
        case .activities:
            return ["⚽️", "🏀", "🏈", "⚾️", "🥎", "🎾", "🏐", "🏉", "🥏", "🎱",
                    "🪀", "🏓", "🏸", "🏒", "🏑", "🥍", "🏏", "🪃", "🥅", "⛳️",
                    "🪁", "🏹", "🎣", "🤿", "🥊", "🥋", "🎽", "🛹", "🛼", "🛷",
                    "⛸", "🥌", "🎿", "⛷", "🏂", "🪂", "🏋️", "🤼", "🤸", "⛹️",
                    "🤺", "🤾", "🏌️", "🏇", "🧘", "🏄", "🏊", "🤽", "🚣", "🧗",
                    "🚵", "🚴", "🏆", "🥇", "🥈", "🥉", "🏅", "🎖", "🏵", "🎗",
                    "🎫", "🎟", "🎪", "🤹", "🎭", "🩰", "🎨", "🎬", "🎤", "🎧",
                    "🎼", "🎹", "🥁", "🪘", "🎷", "🎺", "🎸", "🪕", "🎻", "🎲"]
        case .travel:
            return ["🚗", "🚕", "🚙", "🚌", "🚎", "🏎", "🚓", "🚑", "🚒", "🚐",
                    "🛻", "🚚", "🚛", "🚜", "🦽", "🦼", "🛵", "🏍", "🛺", "🚲",
                    "🛴", "🚨", "🚔", "🚍", "🚘", "🚖", "🚡", "🚠", "🚟", "🚃",
                    "🚋", "🚞", "🚝", "🚄", "🚅", "🚈", "🚂", "🚆", "🚇", "🚊",
                    "🚉", "✈️", "🛫", "🛬", "🛩", "💺", "🛰", "🚀", "🛸", "🚁",
                    "🛶", "⛵️", "🚤", "🛥", "🛳", "⛴", "🚢", "⚓️", "⛽️", "🚧",
                    "🚦", "🚥", "🗺", "🗿", "🗽", "🗼", "🏰", "🏯", "🏟", "🎡",
                    "🎢", "🎠", "⛲️", "⛱", "🏖", "🏝", "🏜", "🌋", "⛰", "🏔",
                    "🗻", "🏕", "⛺️", "🏠", "🏡", "🏘", "🏚", "🏗", "🏢", "🏬",
                    "🏣", "🏤", "🏥", "🏦", "🏨", "🏪", "🏫", "🏩", "💒", "🏛"]
        case .objects:
            return ["⌚️", "📱", "💻", "⌨️", "🖥", "🖨", "🖱", "🖲", "🕹", "🗜",
                    "💽", "💾", "💿", "📀", "📼", "📷", "📸", "📹", "🎥", "📽",
                    "🎞", "📞", "☎️", "📟", "📠", "📺", "📻", "🎙", "🎚", "🎛",
                    "🧭", "⏱", "⏲", "⏰", "🕰", "⌛️", "⏳", "📡", "🔋", "🔌",
                    "💡", "🔦", "🕯", "🪔", "🧯", "🛢", "💸", "💵", "💴", "💶",
                    "💷", "🪙", "💰", "💳", "💎", "⚖️", "🪜", "🧰", "🔧", "🔨",
                    "⚒", "🛠", "⛏", "🪓", "🪚", "🔩", "⚙️", "🧱", "⛓", "🧲",
                    "🔫", "💣", "🧨", "🪃", "🔪", "🗡", "⚔️", "🛡", "🚬", "⚰️",
                    "🪦", "⚱️", "🏺", "🔮", "📿", "🧿", "💈", "⚗️", "🔭", "🔬"]
        case .symbols:
            return ["❤️", "🧡", "💛", "💚", "💙", "💜", "🖤", "🤍", "🤎", "💔",
                    "❣️", "💕", "💞", "💓", "💗", "💖", "💘", "💝", "💟", "☮️",
                    "✝️", "☪️", "🕉", "☸️", "✡️", "🔯", "🕎", "☯️", "☦️", "🛐",
                    "⛎", "♈️", "♉️", "♊️", "♋️", "♌️", "♍️", "♎️", "♏️", "♐️",
                    "♑️", "♒️", "♓️", "🆔", "⚛️", "🉑", "☢️", "☣️", "📴", "📳",
                    "🈶", "🈚️", "🈸", "🈺", "🈷️", "✴️", "🆚", "💮", "🉐", "㊙️",
                    "㊗️", "🈴", "🈵", "🈹", "🈲", "🅰️", "🅱️", "🆎", "🆑", "🅾️",
                    "🆘", "❌", "⭕️", "🛑", "⛔️", "📛", "🚫", "💯", "💢", "♨️",
                    "🚷", "🚯", "🚳", "🚱", "🔞", "📵", "🚭", "❗️", "❓", "‼️",
                    "⁉️", "🔅", "🔆", "〽️", "⚠️", "🚸", "🔱", "⚜️", "🔰", "♻️"]
        case .flags:
            return ["🏁", "🚩", "🎌", "🏴", "🏳️", "🏳️‍🌈", "🏳️‍⚧️", "🏴‍☠️", "🇺🇸", "🇬🇧",
                    "🇨🇦", "🇦🇺", "🇮🇪", "🇳🇿", "🇫🇷", "🇩🇪", "🇮🇹", "🇪🇸", "🇵🇹", "🇳🇱",
                    "🇧🇪", "🇨🇭", "🇦🇹", "🇸🇪", "🇳🇴", "🇩🇰", "🇫🇮", "🇮🇸", "🇯🇵", "🇰🇷",
                    "🇨🇳", "🇮🇳", "🇧🇷", "🇲🇽", "🇦🇷", "🇿🇦", "🇪🇬", "🇬🇷", "🇹🇷", "🇮🇱"]
        }
    }
}
