import Foundation
import Testing

@Suite("Server port validation")
struct ServerPortTests {
    @Test(arguments: ["1", "9091", "65535", " 8080 ", "0009"])
    func acceptsWholePortsInRange(_ text: String) {
        #expect(ServerPort.parse(text) != nil)
        #expect(ServerPort.validationMessage(for: text) == nil)
    }

    @Test func parsesTheValue() {
        #expect(ServerPort.parse("9091") == 9091)
        #expect(ServerPort.parse(" 8080 ") == 8080)
        #expect(ServerPort.parse("0009") == 9)
        #expect(ServerPort.parse("1") == 1)
        #expect(ServerPort.parse("65535") == 65535)
    }

    @Test(arguments: ["", "   ", "abc", "0", "65536", "99999", "-1", "+80", "9091.5", "1e3", "80 80",
                      "\u{FF19}\u{FF10}\u{FF19}\u{FF11}", "99999999999999999999999999"])
    func rejectsBlankNonDigitAndOutOfRangeInput(_ text: String) {
        #expect(ServerPort.parse(text) == nil)
        #expect(ServerPort.validationMessage(for: text) != nil)
    }

    @Test func neverSubstitutesADefaultPort() {
        // The old behaviour was `Int(text) ?? 9091`, which silently saved these.
        #expect(ServerPort.parse("") != 9091)
        #expect(ServerPort.parse("abc") != 9091)
        #expect(ServerPort.parse("99999") != 9091)
    }
}
