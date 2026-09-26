import XCTest

/// Hermetic check that `Resources/TransmissionRemote.sdef` and
/// `Sources/Scripting.swift` haven't drifted apart. `Scripting.swift` itself
/// isn't compiled into the test bundle (it depends on `AppDelegate`/
/// `MainWindowController`, which aren't), so this compares the two source
/// texts directly rather than resolving classes at runtime: every `cocoa
/// class="..."` the sdef declares must appear as an `@objc(...)` declaration
/// in `Scripting.swift`. Catches a renamed/removed command or class without
/// launching the app (unlike `scripts/test-applescript.sh`, which drives the
/// real dictionary against the Docker fixture but requires a built app and is
/// opt-in).
final class ScriptingDictionaryTests: XCTestCase {
    /// Resolved from this source file's own path so it works regardless of the
    /// process's current working directory (same pattern as
    /// `FixtureTransmissionTests.scratchDownloadsDir`).
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // repo root
    }

    private func loadDocument() throws -> XMLDocument {
        let url = Self.repoRoot.appendingPathComponent("Resources/TransmissionRemote.sdef")
        return try XMLDocument(contentsOf: url, options: [])
    }

    private func scriptingSourceText() throws -> String {
        let url = Self.repoRoot.appendingPathComponent("Sources/Scripting.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Every `<command>`'s `cocoa class` must have a matching `@objc(Name)`
    /// declaration in `Scripting.swift`.
    func testEveryCommandCocoaClassExistsInScriptingSwift() throws {
        let document = try loadDocument()
        let source = try scriptingSourceText()
        let commands = try document.nodes(forXPath: "//command")
        XCTAssertFalse(commands.isEmpty, "expected at least one <command> in the sdef")

        for command in commands {
            guard let element = command as? XMLElement else { continue }
            let name = element.attribute(forName: "name")?.stringValue ?? "<unnamed>"
            guard let cocoaClass = try element.nodes(forXPath: "cocoa/@class").first?.stringValue else {
                XCTFail("command '\(name)' has no <cocoa class=\"...\">")
                continue
            }
            XCTAssertTrue(
                source.contains("@objc(\(cocoaClass))"),
                "command '\(name)' declares cocoa class '\(cocoaClass)', with no matching "
                + "@objc(\(cocoaClass)) in Scripting.swift — renamed or removed?")
        }
    }

    /// Every `<class>`'s `cocoa class` must likewise exist in `Scripting.swift`.
    func testEveryClassCocoaClassExistsInScriptingSwift() throws {
        let document = try loadDocument()
        let source = try scriptingSourceText()
        let classes = try document.nodes(forXPath: "//class")
        XCTAssertFalse(classes.isEmpty, "expected at least one <class> in the sdef")

        for classNode in classes {
            guard let element = classNode as? XMLElement else { continue }
            let name = element.attribute(forName: "name")?.stringValue ?? "<unnamed>"
            guard let cocoaClass = try element.nodes(forXPath: "cocoa/@class").first?.stringValue else {
                XCTFail("class '\(name)' has no <cocoa class=\"...\">")
                continue
            }
            XCTAssertTrue(
                source.contains("@objc(\(cocoaClass))"),
                "class '\(name)' declares cocoa class '\(cocoaClass)', with no matching "
                + "@objc(\(cocoaClass)) in Scripting.swift.")
        }
    }

    /// Every `@objc(...)`-named command class in `Scripting.swift` should also
    /// be referenced by the sdef — catches a class that was added/kept in code
    /// but never wired into the dictionary (or renamed there instead).
    func testEveryScriptingSwiftCommandClassIsInSdef() throws {
        let document = try loadDocument()
        let source = try scriptingSourceText()
        let declaredClasses = source.components(separatedBy: "@objc(").dropFirst().compactMap {
            $0.split(separator: ")").first.map(String.init)
        }
        let sdefCocoaClasses = Set(
            try document.nodes(forXPath: "//cocoa/@class").compactMap { $0.stringValue })

        for declared in declaredClasses {
            XCTAssertTrue(
                sdefCocoaClasses.contains(declared),
                "'\(declared)' is @objc-declared in Scripting.swift but no sdef <cocoa class> "
                + "references it — dead code, or the sdef fell out of sync?")
        }
    }
}
