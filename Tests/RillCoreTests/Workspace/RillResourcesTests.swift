import XCTest

@testable import RillCore

final class RillResourcesTests: XCTestCase {
    func testInstalledResourcesResolveAcrossBundleLayouts() throws {
        for layout in ["", "Rill_Rill.bundle", "Rill_Rill.bundle/Contents/Resources"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "rill-resource-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let app = root.appendingPathComponent("Relocated Rill.app")
            let resources = app.appendingPathComponent("Contents/Resources")
            let directory = layout.isEmpty ? resources : resources.appendingPathComponent(layout)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let info: [String: String] = [
                "CFBundleIdentifier": "test.rill." + UUID().uuidString,
                "CFBundlePackageType": "APPL", "CFBundleExecutable": "Rill",
            ]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: app.appendingPathComponent("Contents/Info.plist"))
            let help = directory.appendingPathComponent("Help.json")
            try Data("[]".utf8).write(to: help)
            let bundle = try XCTUnwrap(Bundle(url: app))
            XCTAssertEqual(
                RillResources.url(forResource: "Help", withExtension: "json", bundle: bundle)?
                    .standardizedFileURL, help.standardizedFileURL)
        }
    }
    func testMissingOrEscapingResourceReturnsNilInsteadOfTrapping() throws {
        XCTAssertNil(
            RillResources.url(forResource: "absent-" + UUID().uuidString, withExtension: "json"))
        XCTAssertNil(RillResources.url(forResource: "../Help", withExtension: "json"))
        XCTAssertNil(RillResources.url(forResource: "Help", withExtension: "../json"))
    }
}
