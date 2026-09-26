import XCTest

final class SMBMountResolverTests: XCTestCase {
    private func mount(_ remountURL: String, _ mountPoint: String) -> SMBMountResolver.MountEntry {
        SMBMountResolver.MountEntry(remountURL: URL(string: remountURL)!, mountPoint: mountPoint)
    }

    // MARK: - parseSMBReference

    func testParsesPlainReference() {
        let ref = SMBMountResolver.parseSMBReference("smb://host/share/sub/path")
        XCTAssertEqual(ref?.host, "host")
        XCTAssertEqual(ref?.share, "share")
        XCTAssertEqual(ref?.subpath, "sub/path")
    }

    func testStripsEmbeddedUsername() {
        XCTAssertEqual(SMBMountResolver.parseSMBReference("smb://nick@n/Undupe")?.host, "n")
        XCTAssertEqual(SMBMountResolver.parseSMBReference("smb://guest@ZimaOS/Share")?.host, "zimaos")
    }

    func testStripsLocalAndBonjourSuffixes() {
        XCTAssertEqual(SMBMountResolver.parseSMBReference("smb://host.local/share")?.host, "host")
        XCTAssertEqual(SMBMountResolver.parseSMBReference("smb://host._smb._tcp.local/share")?.host, "host")
    }

    func testStripsTrailingDot() {
        XCTAssertEqual(SMBMountResolver.parseSMBReference("smb://host./share")?.host, "host")
    }

    func testShareNameComparedCaseInsensitively() {
        XCTAssertEqual(SMBMountResolver.parseSMBReference("smb://host/ZimaOS-HD")?.share, "zimaos-hd")
    }

    func testPercentEncodedSubpathDecoded() {
        XCTAssertEqual(SMBMountResolver.parseSMBReference("smb://host/share/My%20Folder")?.subpath, "My Folder")
    }

    func testNoShareReturnsNil() {
        XCTAssertNil(SMBMountResolver.parseSMBReference("smb://host"))
    }

    func testNonSMBSchemeReturnsNil() {
        XCTAssertNil(SMBMountResolver.parseSMBReference("afp://host/share"))
        XCTAssertNil(SMBMountResolver.parseSMBReference("/Volumes/Video"))
    }

    // MARK: - resolveMountPoint

    func testExactHostAndShareMatch() {
        let mounts = [mount("smb://nick@n/Undupe", "/Volumes/Undupe")]
        XCTAssertEqual(SMBMountResolver.resolveMountPoint(forSMBReference: "smb://n/Undupe", mounts: mounts),
                       "/Volumes/Undupe")
    }

    func testSubpathAppendedToResolvedMountPoint() {
        let mounts = [mount("smb://nick@zimaos/ZimaOS-HD", "/Volumes/ZimaOS-HD")]
        XCTAssertEqual(
            SMBMountResolver.resolveMountPoint(forSMBReference: "smb://ZimaOS/ZimaOS-HD/AppData/transmission-openvpn/downloads",
                                                mounts: mounts),
            "/Volumes/ZimaOS-HD/AppData/transmission-openvpn/downloads")
    }

    func testFallsBackToUnambiguousShareNameMatchWhenHostDiffers() {
        // Typed "ZimaOS", Finder actually mounted it resolved as "ZimaOS.local".
        let mounts = [mount("smb://guest@ZimaOS.local/ZimaOS-HD", "/Volumes/ZimaOS-HD")]
        XCTAssertEqual(SMBMountResolver.resolveMountPoint(forSMBReference: "smb://ZimaOS/ZimaOS-HD", mounts: mounts),
                       "/Volumes/ZimaOS-HD")
    }

    func testAmbiguousShareNameMatchAcrossHostsReturnsNil() {
        let mounts = [
            mount("smb://host1/Share", "/Volumes/Share"),
            mount("smb://host2/Share", "/Volumes/Share-1"),
        ]
        XCTAssertNil(SMBMountResolver.resolveMountPoint(forSMBReference: "smb://host3/Share", mounts: mounts))
    }

    func testMountPointWithCollisionSuffixResolvesCorrectly() {
        let mounts = [mount("smb://nas/Video", "/Volumes/Video-1")]
        XCTAssertEqual(SMBMountResolver.resolveMountPoint(forSMBReference: "smb://nas/Video/Show", mounts: mounts),
                       "/Volumes/Video-1/Show")
    }

    func testNoMatchingMountReturnsNil() {
        XCTAssertNil(SMBMountResolver.resolveMountPoint(forSMBReference: "smb://nas/Video", mounts: []))
    }

    // MARK: - shareRootReference

    func testShareRootReferenceTruncatesDeepSubpath() {
        XCTAssertEqual(SMBMountResolver.shareRootReference("smb://n/Undupe/2026/09"), "smb://n/Undupe")
    }

    func testShareRootReferencePreservesUserAndCasing() {
        XCTAssertEqual(SMBMountResolver.shareRootReference("smb://nick@ZimaOS/ZimaOS-HD/AppData/x"),
                       "smb://nick@ZimaOS/ZimaOS-HD")
    }

    func testShareRootReferenceUnchangedWhenAlreadyJustShare() {
        XCTAssertEqual(SMBMountResolver.shareRootReference("smb://n/Undupe"), "smb://n/Undupe")
    }

    func testShareRootReferenceNilForNonSMBOrShareless() {
        XCTAssertNil(SMBMountResolver.shareRootReference("smb://n"))
        XCTAssertNil(SMBMountResolver.shareRootReference("/Volumes/Video"))
    }

    func testNonParseableMountEntryIsIgnored() {
        // A mount whose remount URL isn't an smb:// reference (e.g. a local disk)
        // must never accidentally match.
        let mounts = [
            SMBMountResolver.MountEntry(remountURL: URL(string: "file:///")!, mountPoint: "/"),
            mount("smb://nas/Video", "/Volumes/Video"),
        ]
        XCTAssertEqual(SMBMountResolver.resolveMountPoint(forSMBReference: "smb://nas/Video", mounts: mounts),
                       "/Volumes/Video")
    }
}
