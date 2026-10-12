import XCTest
@testable import OldMansBookClub

/// #204 PR 6 (U12; docs/SEND_REQUIREMENTS.md O3, O5, O6) — every chat is in tap-time order,
/// whatever order messages arrive in; a late arrival is flagged and counts as new.
final class ChatOrderTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let me = UUID(), dixie = UUID(), club = UUID()

    private func message(_ seconds: Double, from sender: UUID? = nil, received: Double? = nil,
                         id: UUID = UUID(), body: String = "") -> Message {
        Message(id: id, clubId: club, senderId: sender ?? dixie, senderName: "x", type: .text, body: body,
                mediaUrl: nil, durationSeconds: nil, sentAt: t0.addingTimeInterval(seconds),
                receivedAt: received.map { t0.addingTimeInterval($0) })
    }

    // MARK: - O3: placed by tap time, not arrival

    func testO3AVideoTappedBeforeAVoiceMessageStaysAboveItWhenItsUploadFinishesLater() {
        // The 2026-10-11 report: video, then voice; the voice lands first, then the video.
        let voice = message(10, from: me, body: "voice")
        let video = message(5, from: me, body: "video")
        var chat = [voice]   // newest first

        chat.insert(video, at: ChatOrder.insertionIndex(of: video, in: chat))

        XCTAssertEqual(chat.map(\.body), ["voice", "video"], "newest first: the video sits above the voice on screen")
    }

    func testALiveMessageTappedEarlierGoesWhereItWasTappedNotAtTheBottom() {
        var chat = [message(30, body: "c"), message(20, body: "b"), message(10, body: "a")]
        let late = message(15, body: "late")

        chat.insert(late, at: ChatOrder.insertionIndex(of: late, in: chat))

        XCTAssertEqual(chat.map(\.body), ["c", "b", "late", "a"])
    }

    func testTheNewestStillGoesAtTheBottom() {
        let chat = [message(20), message(10)]
        XCTAssertEqual(ChatOrder.insertionIndex(of: message(30), in: chat), 0)
    }

    func testEqualTapTimesKeepOneOrderHoweverTheyArrive() {
        let a = message(10, id: UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!, body: "a")
        let b = message(10, id: UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!, body: "b")
        var oneWay = [a]; oneWay.insert(b, at: ChatOrder.insertionIndex(of: b, in: oneWay))
        var otherWay = [b]; otherWay.insert(a, at: ChatOrder.insertionIndex(of: a, in: otherWay))
        XCTAssertEqual(oneWay.map(\.body), otherWay.map(\.body))
    }

    func testALateArrivalFromAFetchIsMergedAtItsTapTime() {
        let seen = [message(30, body: "c"), message(10, body: "a")]
        let late = message(20, received: 300, body: "late")

        let merged = ChatCache.merge(existing: seen, incoming: [late], myUserId: me).messages

        XCTAssertEqual(merged.map(\.body), ["c", "late", "a"])
    }

    // MARK: - O5: a late arrival counts as new

    func testTheReadMarkerGoesToTheLatestToArriveNotTheNewestByTapTime() {
        // Marking the newest by tap time ("c") would leave the late arrival behind the marker.
        let chat = [message(30, received: 31, body: "c"), message(20, received: 300, body: "late"),
                    message(10, received: 11, body: "a")]
        XCTAssertEqual(ChatOrder.latestArrival(in: chat)?.body, "late")
    }

    func testWithoutArrivalTimesTheReadMarkerFallsBackToTapTime() {
        // Messages from a server before 2.2 carry no received_at.
        XCTAssertEqual(ChatOrder.latestArrival(in: [message(10, body: "a"), message(30, body: "c")])?.body, "c")
    }

    // MARK: - O6: "↑ New message above"

    func testTheChipPointsAtTheOldestNewMessageFromOthersAboveWhatWasSeen() {
        let previous = [message(30, body: "c"), message(10, body: "a")]
        let lateOld = message(12, body: "late-old"), lateNew = message(25, body: "late-new")
        let current = ChatOrder.sorted(previous + [lateOld, lateNew])

        XCTAssertEqual(ChatOrder.arrivedAbove(previous: previous, current: current, me: me), lateOld.id,
                       "reading down from the oldest covers the rest")
    }

    func testNoChipForNewMessagesAtTheBottomForMyOwnOrOnAFirstLoad() {
        let previous = [message(30), message(10)]
        let atBottom = message(40)
        let mine = message(20, from: me)

        XCTAssertNil(ChatOrder.arrivedAbove(previous: previous, current: ChatOrder.sorted(previous + [atBottom]), me: me),
                     "the bottom is where the reader is — the usual 'New message' pill covers it")
        XCTAssertNil(ChatOrder.arrivedAbove(previous: previous, current: ChatOrder.sorted(previous + [mine]), me: me))
        XCTAssertNil(ChatOrder.arrivedAbove(previous: [], current: previous, me: me), "nothing was seen before")
    }
}
