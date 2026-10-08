import XCTest
@testable import VMCore

final class KeyMapTests: XCTestCase {
    func testTextWithShiftAndReturn() throws {
        XCTAssertEqual(try KeyMap.strokes(forText: "Hi!\n"), [
            KeyStroke(keyCode: 4, modifiers: .shift, characters: "H"),
            KeyStroke(keyCode: 34, modifiers: [], characters: "i"),
            KeyStroke(keyCode: 18, modifiers: .shift, characters: "!"),
            KeyStroke(keyCode: 36, modifiers: [], characters: "\r"),
        ])
    }

    func testAllPrintableASCIIIsSupported() throws {
        let printable = String((32...126).map { Character(Unicode.Scalar($0)!) })
        XCTAssertEqual(try KeyMap.strokes(forText: printable + "\t").count, printable.count + 1)
    }

    /// Foco de revisión 1: texto no ASCII → error con los caracteres, sin teclear nada.
    func testNonASCIIIsRejectedListingCharacters() {
        XCTAssertThrowsError(try KeyMap.strokes(forText: "ñandú 🙂")) { error in
            XCTAssertEqual(error as? KeyMapError, .unsupportedCharacters("ñú🙂"))
            XCTAssertTrue("\(error)".contains("ñú🙂"))
        }
    }

    func testTextTooLong() {
        XCTAssertThrowsError(try KeyMap.strokes(forText: String(repeating: "a", count: 10_001))) { error in
            XCTAssertEqual(error as? KeyMapError, .textTooLong(10_001))
        }
    }

    func testCombos() throws {
        XCTAssertEqual(try KeyMap.stroke(forCombo: "cmd+space"), KeyStroke(keyCode: 49, modifiers: .command, characters: " "))
        XCTAssertEqual(try KeyMap.stroke(forCombo: "ctrl+alt+t"), KeyStroke(keyCode: 17, modifiers: [.control, .option], characters: "t"))
        XCTAssertEqual(try KeyMap.stroke(forCombo: "CTRL+C"), KeyStroke(keyCode: 8, modifiers: .control, characters: "c"))
        XCTAssertEqual(try KeyMap.stroke(forCombo: "return"), KeyStroke(keyCode: 36, modifiers: [], characters: "\r"))
        XCTAssertEqual(try KeyMap.stroke(forCombo: "shift+tab"), KeyStroke(keyCode: 48, modifiers: .shift, characters: "\t"))
        XCTAssertEqual(try KeyMap.stroke(forCombo: "cmd++"), KeyStroke(keyCode: 24, modifiers: [.command, .shift], characters: "+"))
        XCTAssertEqual(try KeyMap.stroke(forCombo: "f5"), KeyStroke(keyCode: 96, modifiers: [], characters: ""))
        XCTAssertEqual(try KeyMap.stroke(forCombo: "super"), KeyStroke(keyCode: 55, modifiers: [], characters: ""))
        XCTAssertEqual(try KeyMap.stroke(forCombo: " Cmd + Shift + 4 "), KeyStroke(keyCode: 21, modifiers: [.command, .shift], characters: "4"))
    }

    func testBadCombos() {
        XCTAssertThrowsError(try KeyMap.stroke(forCombo: "")) { XCTAssertEqual($0 as? KeyMapError, .emptyCombo) }
        XCTAssertThrowsError(try KeyMap.stroke(forCombo: "ctrl+foo")) { XCTAssertEqual($0 as? KeyMapError, .unknownKey("foo")) }
        XCTAssertThrowsError(try KeyMap.stroke(forCombo: "hyper+a")) { XCTAssertEqual($0 as? KeyMapError, .unknownKey("hyper")) }
        XCTAssertThrowsError(try KeyMap.stroke(forCombo: "ctrl+ñ")) { XCTAssertEqual($0 as? KeyMapError, .unknownKey("ñ")) }
    }
}
