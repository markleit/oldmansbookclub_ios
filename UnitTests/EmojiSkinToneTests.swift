import XCTest
@testable import OldMansBookClub

/// #173 — skin-tone application is pure Unicode surgery; a wrong scalar order or a leftover
/// variation selector renders as the base emoji plus a loose color swatch, which the compiler
/// can't catch and a glance at the grid easily misses.
final class EmojiSkinToneTests: XCTestCase {

    func testNoneLeavesEveryEmojiUnchanged() {
        for emoji in ["👍", "☝️", "🕵️", "❤️", "🐶"] {
            XCTAssertEqual(EmojiSkinTone.none.apply(to: emoji), emoji)
        }
    }

    func testModifierBaseGetsTheToneAppended() {
        XCTAssertEqual(EmojiSkinTone.light.apply(to: "👍"), "👍🏻")
        XCTAssertEqual(EmojiSkinTone.mediumLight.apply(to: "👍"), "👍🏼")
        XCTAssertEqual(EmojiSkinTone.medium.apply(to: "👍"), "👍🏽")
        XCTAssertEqual(EmojiSkinTone.mediumDark.apply(to: "👍"), "👍🏾")
        XCTAssertEqual(EmojiSkinTone.dark.apply(to: "👍"), "👍🏿")
    }

    func testVariationSelectorIsReplacedNotKept() {
        // ☝️ is U+261D U+FE0F; the toned form must be U+261D U+1F3FF with no FE0F.
        XCTAssertEqual(Array(EmojiSkinTone.dark.apply(to: "☝️").unicodeScalars), ["\u{261D}", "\u{1F3FF}"])
        XCTAssertEqual(EmojiSkinTone.dark.apply(to: "🏋️"), "🏋🏿")
    }

    func testZWJSuffixIsPreserved() {
        XCTAssertEqual(EmojiSkinTone.medium.apply(to: "🕵️‍♂️"), "🕵🏽‍♂️")
    }

    func testNonBasesAndExclusionsAreUnchanged() {
        for emoji in ["❤️", "🐶", "😀", "🎉", "🧞", "🤼"] {
            XCTAssertEqual(EmojiSkinTone.dark.apply(to: emoji), emoji, "\(emoji) must not take a tone")
        }
    }

    func testMultiPersonSequencesAreUnchanged() {
        XCTAssertEqual(EmojiSkinTone.dark.apply(to: "🧑‍🤝‍🧑"), "🧑‍🤝‍🧑")
    }

    func testTonedResultIsOneCharacterAndFitsTheServerLimit() {
        // The picker hands onPick a single Character, and SetReaction rejects > 16 UTF-16 units.
        for tone in EmojiSkinTone.allCases {
            for emoji in ["👍", "☝️", "🕵️‍♂️", "🫶", "🧑"] {
                let toned = tone.apply(to: emoji)
                XCTAssertEqual(toned.count, 1, "\(toned) split into multiple Characters")
                XCTAssertLessThanOrEqual(toned.utf16.count, 16)
            }
        }
    }

    func testCanTone() {
        XCTAssertTrue(EmojiSkinTone.canTone("👍"))
        XCTAssertTrue(EmojiSkinTone.canTone("☝️"))
        XCTAssertFalse(EmojiSkinTone.canTone("😂"))
        XCTAssertFalse(EmojiSkinTone.canTone("🤼"))
    }

    // Per-emoji memory, like the system keyboard: a tone chosen for 👍 must not leak onto ✋, and
    // choosing the default forgets the entry rather than storing it.
    func testRememberedTonesArePerEmoji() {
        let key = "emojiSkinTones"
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.removeObject(forKey: key)

        EmojiSkinTone.remember(.dark, for: "👍")
        XCTAssertEqual(EmojiSkinTone.remembered(for: "👍"), .dark)
        XCTAssertEqual(EmojiSkinTone.remembered(for: "✋"), .none)

        EmojiSkinTone.remember(.none, for: "👍")
        XCTAssertEqual(EmojiSkinTone.remembered(for: "👍"), .none)
        XCTAssertTrue(EmojiSkinTone.rememberedTones().isEmpty)
    }
}
