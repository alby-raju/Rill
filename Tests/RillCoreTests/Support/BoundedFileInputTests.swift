import XCTest

@testable import RillCore

final class BoundedFileInputTests: XCTestCase {
    func testExactLimitAndUnsafeFileKinds() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("input.json")
        let data = Data("fixture".utf8)
        try data.write(to: file)
        XCTAssertEqual(try BoundedFileInput.read(file, limit: data.count), data)
        XCTAssertThrowsError(try BoundedFileInput.read(file, limit: data.count - 1))
        XCTAssertThrowsError(try BoundedFileInput.read(file, limit: 0))
        XCTAssertThrowsError(try BoundedFileInput.read(root, limit: 1024))
        XCTAssertThrowsError(
            try BoundedFileInput.read(root.appendingPathComponent("missing"), limit: 1024))
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertThrowsError(try BoundedFileInput.read(link, limit: 1024))
    }
}
