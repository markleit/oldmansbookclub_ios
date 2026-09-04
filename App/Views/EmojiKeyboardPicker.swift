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
                    ForEach(selectedCategory.emoji, id: \.self) { emoji in
                        Button {
                            if let char = emoji.first { onPick(char) }
                            dismiss()
                        } label: {
                            Text(emoji)
                                .font(.system(size: 30))
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.plain)
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
