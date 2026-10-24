import XCTest
import Security
@testable import RillCore

private struct FixtureTLSIdentity: TLSIdentityProvider, @unchecked Sendable {
    let value: SecIdentity
    func identity(for reference: Data) throws -> SecIdentity { value }
}
@MainActor final class TLSProfileTests: XCTestCase {
    private func directory() throws -> URL { URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["RILL_TEST_TLS_DIR"])) }
    private func profile() throws -> TLSProfile {
        var profile = TLSProfile(); profile.name = "Fixture trust"; profile.mode = .custom; profile.includeSystemRoots = false
        profile.anchors = [try Data(contentsOf: directory().appendingPathComponent("ca.der"))]; return profile
    }
    private func draft(_ key: String = "RILL_TEST_TLS_URL") throws -> RequestDraft {
        var draft = RequestDraft(); draft.url = try XCTUnwrap(ProcessInfo.processInfo.environment[key]) + "/json"; return draft
    }
    func testCustomTrustSucceedsWithoutChangingSystemTrust() async throws {
        var request = try draft()
        do { _ = try await RequestEngine.execute(request, environment: nil); XCTFail("Untrusted certificate accepted by defaults") } catch { }
        let trust = try profile(); request.tlsProfileID = trust.id
        let exchange = try await RequestEngine.execute(request, environment: nil, tlsProfiles: [trust])
        XCTAssertEqual(exchange.status, 200)
        request.tlsProfileID = nil
        do { _ = try await RequestEngine.execute(request, environment: nil); XCTFail("Custom trust changed system defaults") } catch { }
    }
    func testCustomTrustStillRejectsHostnameMismatchAndInsecureIsExplicit() async throws {
        var request = try draft(); request.url = request.url.replacingOccurrences(of: "localhost", with: "127.0.0.1")
        var trust = try profile(); request.tlsProfileID = trust.id
        do { _ = try await RequestEngine.execute(request, environment: nil, tlsProfiles: [trust]); XCTFail("Hostname mismatch accepted") } catch { }
        trust.mode = .insecure
        let exchange = try await RequestEngine.execute(request, environment: nil, tlsProfiles: [trust])
        XCTAssertEqual(exchange.status, 200)
    }
    func testMTLSRequiresIdentityAndUsesInMemoryFixtureWithoutKeychainImport() async throws {
        var request = try draft("RILL_TEST_MTLS_URL")
        var trust = try profile(); request.tlsProfileID = trust.id
        do { _ = try await RequestEngine.execute(request, environment: nil, tlsProfiles: [trust]); XCTFail("mTLS succeeded without identity") } catch { }
        guard #available(macOS 15, *) else { throw XCTSkip("Memory-only identity fixture requires macOS 15; macOS 14 Keychain acceptance is manual.") }
        let data = try Data(contentsOf: directory().appendingPathComponent("client.p12"))
        var items: CFArray?
        XCTAssertEqual(SecPKCS12Import(data as CFData, [kSecImportExportPassphrase: "rill-fixture", kSecImportToMemoryOnly: true] as CFDictionary, &items), errSecSuccess)
        let dictionaries = try XCTUnwrap(items as? [[String: Any]])
        let identity = try XCTUnwrap(dictionaries.first?[kSecImportItemIdentity as String]) as! SecIdentity
        trust.identityReference = Data("fixture-memory-identity".utf8); trust.requiresClientIdentity = true
        let exchange = try await RequestEngine.execute(request, environment: nil, tlsProfiles: [trust], identities: FixtureTLSIdentity(value: identity))
        XCTAssertEqual(exchange.status, 200)
    }
    func testPEMAndDERParsingBoundsAndMissingProfileOrIdentity() throws {
        let pem = try Data(contentsOf: directory().appendingPathComponent("ca.pem"))
        let der = try Data(contentsOf: directory().appendingPathComponent("ca.der"))
        XCTAssertEqual(try TLSProfiles.certificateData(pem), der)
        XCTAssertEqual(try TLSProfiles.certificateData(der), der)
        XCTAssertThrowsError(try TLSProfiles.certificateData(Data("not a certificate".utf8)))
        XCTAssertThrowsError(try TLSProfiles.certificateData(Data(repeating: 0, count: 1024 * 1024 + 1)))
        XCTAssertThrowsError(try TLSProfiles.selected(UUID(), from: []))
        var trust = TLSProfile(); trust.requiresClientIdentity = true
        XCTAssertThrowsError(try TLSProfiles.selected(trust.id, from: [trust]))
    }
    func testImportRetainsTrustButRemapsProfileAndRequiresIdentityReselection() throws {
        var trust = try profile(); trust.identityReference = Data("source-keychain-reference".utf8); trust.requiresClientIdentity = true
        var request = RequestDraft(); request.tlsProfileID = trust.id
        var incoming = Workspace(); incoming.requests = [request]; incoming.tlsProfiles = [trust]
        let merged = try WorkspaceImport.merging(incoming, into: Workspace())
        XCTAssertNotEqual(merged.tlsProfiles![0].id, trust.id)
        XCTAssertEqual(merged.requests[0].tlsProfileID, merged.tlsProfiles![0].id)
        XCTAssertEqual(merged.tlsProfiles![0].anchors, trust.anchors)
        XCTAssertNil(merged.tlsProfiles![0].identityReference); XCTAssertTrue(merged.tlsProfiles![0].requiresClientIdentity)
        XCTAssertThrowsError(try TLSProfiles.selected(merged.requests[0].tlsProfileID, from: merged.tlsProfiles!))
    }
    func testMalformedPKCS12ImportDoesNotExposePassphrase() async {
        let manager = TLSIdentityManager()
        do { _ = try await manager.importPKCS12(Data("invalid".utf8), passphrase: "SEEDED_PASSWORD"); XCTFail("Invalid identity accepted") }
        catch { XCTAssertFalse(error.localizedDescription.contains("SEEDED_PASSWORD")) }
    }
}
