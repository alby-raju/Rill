import XCTest
import ZIPFoundation

@testable import RillCore

final class BoundedArchiveTests: XCTestCase {
    private func zip(
        _ files: [(String, Data)], compressed: Bool = false, type: Entry.EntryType = .file
    ) throws -> Data {
        let archive = try Archive(accessMode: .create)
        for (name, data) in files {
            try archive.addEntry(
                with: name, type: type, uncompressedSize: Int64(data.count),
                compressionMethod: compressed ? .deflate : .none
            ) { offset, size in
                data.subdata(in: Int(offset)..<min(data.count, Int(offset) + size))
            }
        }
        return try XCTUnwrap(archive.data)
    }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    func testStoredAndDeflatedEntriesRemainInMemoryWithExactBytes() throws {
        let files = [
            ("bruno.json", Data(#"{"version":"1","name":"API","type":"collection"}"#.utf8)),
            ("Folder/Request.bru", Data(repeating: 65, count: 200_000)),
        ]
        for compressed in [false, true] {
            let restored = try BoundedArchive.readZIP(zip(files, compressed: compressed))
            XCTAssertEqual(restored.map(\.path), files.map(\.0))
            XCTAssertEqual(restored.map(\.data), files.map(\.1))
        }
    }
    func testTraversalAbsoluteWindowsDuplicateUnicodeAndSymlinkPathsReject() throws {
        for path in [
            "../outside.bru", "/absolute.bru", "C:/file.bru", "a\\b.bru", "a//b.bru", "a/./b.bru",
            "a/../../b.bru",
        ] {
            XCTAssertThrowsError(try BoundedArchive.readZIP(zip([(path, Data())])), path)
        }
        for names in [["A.bru", "a.bru"], ["é.bru", "e\u{301}.bru"], ["folder", "folder/a.bru"]] {
            XCTAssertThrowsError(try BoundedArchive.readZIP(zip(names.map { ($0, Data()) })))
        }
        XCTAssertThrowsError(
            try BoundedArchive.readZIP(
                zip([("link.bru", Data("/private/file".utf8))], type: .symlink)))
        XCTAssertThrowsError(try BoundedArchive.readZIP(zip([("nested.zip", Data())])))
    }
    func testSizeCountDepthCRCAndDirectoryMetadataBounds() throws {
        XCTAssertThrowsError(
            try BoundedArchive.readZIP(Data(repeating: 0, count: BoundedArchive.totalBytes + 1)))
        XCTAssertThrowsError(
            try BoundedArchive.readZIP(
                zip(
                    [("bomb.bru", Data(repeating: 0, count: BoundedArchive.fileBytes + 1))],
                    compressed: true)))
        XCTAssertThrowsError(
            try BoundedArchive.readZIP(
                zip([(String(repeating: "a/", count: 16) + "file.bru", Data())])))
        var crc = try zip([("file.bru", Data("content".utf8))])
        crc[30 + "file.bru".utf8.count] ^= 0xff
        XCTAssertThrowsError(try BoundedArchive.readZIP(crc))
        var count = try zip([("file.bru", Data())])
        count[count.count - 12] = 2
        XCTAssertThrowsError(try BoundedArchive.readZIP(count))
        var excessive = try zip([("file.bru", Data())])
        excessive[excessive.count - 12] = 1
        excessive[excessive.count - 11] = 16
        XCTAssertThrowsError(try BoundedArchive.readZIP(excessive))
        var encrypted = try zip([("file.bru", Data())])
        encrypted[6] |= 1
        let central = try XCTUnwrap(encrypted.range(of: Data([0x50, 0x4b, 0x01, 0x02]))).lowerBound
        encrypted[central + 8] |= 1
        XCTAssertThrowsError(try BoundedArchive.readZIP(encrypted))
        var truncated = try zip([("file.bru", Data())])
        truncated.removeLast()
        XCTAssertThrowsError(try BoundedArchive.readZIP(truncated))
    }
    func testFolderReadsOnlyBruMetadataAndRejectsSymlinkAndEscapingDirectory() throws {
        let root = try directory()
        let folder = root.appendingPathComponent("Folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("source".utf8).write(to: folder.appendingPathComponent("request.bru"))
        try Data("UPLOAD_NOT_IMPORTED".utf8).write(to: folder.appendingPathComponent("upload.bin"))
        XCTAssertEqual(try BoundedFileInput.brunoFolder(root).map(\.path), ["Folder/request.bru"])
        let outside = try directory()
        try Data("outside".utf8).write(to: outside.appendingPathComponent("private.bru"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("linked"), withDestinationURL: outside)
        XCTAssertThrowsError(try BoundedFileInput.brunoFolder(root))
        XCTAssertThrowsError(
            try BoundedFileInput.brunoFolder(root.appendingPathComponent("linked")))
    }
    func testPreCancelledArchiveReadCannotPublishFiles() async throws {
        let data = try zip([("request.bru", Data("source".utf8))])
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        let task = Task.detached {
            for await _ in stream { break }
            return try BoundedArchive.readZIP(data)
        }
        task.cancel()
        continuation.finish()
        do {
            _ = try await task.value
            XCTFail("Cancelled read published files")
        } catch { XCTAssertTrue(error is CancellationError) }
    }
    func testNoFollowFileAndBoundedRead() throws {
        let root = try directory()
        let file = root.appendingPathComponent("request.bru")
        try Data("source".utf8).write(to: file)
        XCTAssertEqual(try BoundedFileInput.read(file), Data("source".utf8))
        XCTAssertThrowsError(try BoundedFileInput.read(file, limit: 2))
        let link = root.appendingPathComponent("link.bru")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertThrowsError(try BoundedFileInput.read(link))
    }
}
