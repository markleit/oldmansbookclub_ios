import Foundation
@testable import OldMansBookClub

/// Shared builders so a test says only what it is actually about.
///
/// Message has eighteen fields and a test that spells out all of them buries its one meaningful
/// value in noise — and worse, invites copy-paste tests that assert on fields nobody chose.
enum Fixture {
    static let bookId = UUID(uuidString: "00000000-0000-0000-0000-0000000000B0")!
    static let clubId = UUID(uuidString: "00000000-0000-0000-0000-0000000000C0")!
    static let me = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!
    static let other = UUID(uuidString: "00000000-0000-0000-0000-0000000000BB")!

    /// A fixed instant, so `sentAt` ordering in a test is stated rather than raced.
    static let epoch = Date(timeIntervalSince1970: 1_780_000_000)

    static func message(
        id: UUID = UUID(),
        senderId: UUID = Fixture.other,
        senderName: String = "Other",
        type: MessageType = .text,
        body: String? = "hello",
        secondsAfterEpoch: TimeInterval = 0,
        isDeleted: Bool = false,
        sendState: MessageSendState? = nil,
        clientId: UUID? = nil,
        transcript: String? = nil
    ) -> Message {
        Message(
            id: id,
            clubId: clubId,
            senderId: senderId,
            senderName: senderName,
            senderAvatarUrl: nil,
            type: type,
            body: body,
            mediaUrl: type == .text ? nil : "https://example.invalid/media.m4a",
            durationSeconds: type == .voice ? 5 : nil,
            sentAt: epoch.addingTimeInterval(secondsAfterEpoch),
            isDeleted: isDeleted,
            isForwarded: false,
            sendState: sendState,
            clientId: clientId,
            transcript: transcript
        )
    }

    /// The optimistic bubble a send inserts before the server has confirmed anything: its local
    /// `id` IS the clientId, which is the whole basis of reconciliation.
    static func optimistic(clientId: UUID, body: String = "hello", secondsAfterEpoch: TimeInterval = 0) -> Message {
        message(id: clientId, senderId: me, senderName: "Me", body: body,
                secondsAfterEpoch: secondsAfterEpoch, sendState: .sending)
    }

    /// The server's confirmation of that send: a new server `id`, carrying the original clientId.
    static func confirmed(of clientId: UUID, body: String = "hello", secondsAfterEpoch: TimeInterval = 0) -> Message {
        message(id: UUID(), senderId: me, senderName: "Me", body: body,
                secondsAfterEpoch: secondsAfterEpoch, clientId: clientId)
    }
}
