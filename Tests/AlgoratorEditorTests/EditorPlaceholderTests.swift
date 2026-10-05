import XCTest
@testable import AlgoratorEditor

final class EditorPlaceholderTests: XCTestCase {
    func testEditorLinksAgainstCore() {
        XCTAssertEqual(EditorPlaceholder.schemaVersion, 1)
    }
}
