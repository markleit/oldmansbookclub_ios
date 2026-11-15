import XCTest
@testable import OldMansBookClub

/// #273 / #274 / #279 — on a Mac, RunningBoard kills the hidden app (0xdead10cc) if it's suspended
/// while Metal holds locks on its shader-cache files, unless each file carries RunningBoard's
/// `can-suspend-locked` attribute. RunningBoard itself can't run here (that part was proven on the
/// Mac: tagged → survived suspension, untagged → killed); these prove the app tags exactly the
/// right files, including ones locked at that moment, and re-tags a cache file Metal replaced.
final class MacSuspensionGuardTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("MacSuspensionGuard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// The two layouts seen on the Mac: <cache>/com.apple.metal/<n>/… and
    /// <cache>/<bundle id>/com.apple.metal/<n>/… (plus com.apple.metalfe and archiveUsage.db).
    @discardableResult
    private func file(_ relative: String) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
        return url
    }

    func testTagsEveryMetalCacheFileAndNothingElse() throws {
        let metal = [
            try file("com.apple.metal/16777235_323/functions.data"),
            try file("com.apple.metal/16777235_323/functions.list"),
            try file("com.markleit.oldmansbookclub/com.apple.metal/32024/libraries.data"),
            try file("com.markleit.oldmansbookclub/com.apple.metal/archiveUsage.db/lock.mdb"),
            try file("com.markleit.oldmansbookclub/com.apple.metalfe/cache.data"),
        ]
        let other = [
            try file("com.markleit.oldmansbookclub/Cache.db"),
            try file("something.else/data"),
            try file("com.apple.metal-not-a-folder"),
        ]

        XCTAssertEqual(MacSuspensionGuard.tagMetalCaches(in: root), metal.count)

        for url in metal { XCTAssertTrue(MacSuspensionGuard.isTagged(url), "untagged: \(url.path)") }
        for url in other { XCTAssertFalse(MacSuspensionGuard.isTagged(url), "tagged a non-Metal file: \(url.path)") }
    }

    /// The real situation: Metal holds an exclusive lock on the file while the app tags it.
    func testTagsAFileThatIsLockedRightNow() throws {
        let url = try file("com.apple.metal/32024/libraries.data")
        let fd = open(url.path, O_RDONLY)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)

        MacSuspensionGuard.tagMetalCaches(in: root)

        // The exact name RunningBoard checks (from its own strings: "Ignoring file with can-suspend-locked").
        XCTAssertGreaterThanOrEqual(getxattr(url.path, "com.apple.runningboard.can-suspend-locked", nil, 0, 0, 0), 0)
    }

    /// Runs on every trip to the background: already-tagged files are left alone, and a cache file
    /// Metal replaced since (a new file, no attribute) is tagged again.
    func testTagsOnlyWhatIsNewOnTheNextRun() throws {
        let kept = try file("com.apple.metal/16777235_323/functions.data")
        let replaced = try file("com.apple.metal/16777235_323/functions.list")
        XCTAssertEqual(MacSuspensionGuard.tagMetalCaches(in: root), 2)
        XCTAssertEqual(MacSuspensionGuard.tagMetalCaches(in: root), 0)

        try FileManager.default.removeItem(at: replaced)
        try file("com.apple.metal/16777235_323/functions.list")

        XCTAssertEqual(MacSuspensionGuard.tagMetalCaches(in: root), 1)
        XCTAssertTrue(MacSuspensionGuard.isTagged(kept))
        XCTAssertTrue(MacSuspensionGuard.isTagged(replaced))
    }

    /// libc's answer isn't available in the simulator, so the fallback — where macOS puts the app —
    /// is pinned against the real paths from the reporting Mac.
    func testWorksOutTheCacheFolderFromWhereMacOSPutTheApp() {
        let app = URL(fileURLWithPath: "/private/var/folders/4p/fk0m7kn578s3flykt50gffb00000gn/X/C7AECD50-6489-554D-AFEF-2757BEE7F20C/d/Wrapper/OldMansBookClub.app")
        let expected = URL(fileURLWithPath: "/private/var/folders/4p/fk0m7kn578s3flykt50gffb00000gn/C/com.markleit.oldmansbookclub")
        // /var is a link to /private/var; either spelling is the same folder.
        XCTAssertEqual(MacSuspensionGuard.cacheDirectory(forBundleAt: app, bundleId: "com.markleit.oldmansbookclub")?.standardizedFileURL.path,
                       expected.standardizedFileURL.path)
    }

    func testNoCacheFolderForAnAppThatIsNotInAMacWrapper() {
        let app = URL(fileURLWithPath: "/private/var/containers/Bundle/Application/1234/OldMansBookClub.app")
        XCTAssertNil(MacSuspensionGuard.cacheDirectory(forBundleAt: app, bundleId: "com.markleit.oldmansbookclub"))
    }
}
