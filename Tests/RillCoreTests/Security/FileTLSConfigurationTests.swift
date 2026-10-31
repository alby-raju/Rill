import Security
import XCTest

@testable import RillCore

private struct RejectFileTLSLookups: TLSIdentityProvider {
    func identity(for reference: Data) throws -> SecIdentity { throw TLSError.unavailableIdentity }
}

@MainActor final class FileTLSConfigurationTests: XCTestCase {
    private func file(_ name: String) throws -> Data {
        guard let root = ProcessInfo.processInfo.environment["RILL_TEST_TLS_DIR"] else {
            throw XCTSkip("TLS fixtures required")
        }
        return try Data(contentsOf: URL(fileURLWithPath: root).appendingPathComponent(name))
    }
    private func endpoint(_ mtls: Bool = false) throws -> String {
        try XCTUnwrap(
            ProcessInfo.processInfo.environment[mtls ? "RILL_TEST_MTLS_URL" : "RILL_TEST_TLS_URL"])
    }
    private func request(_ url: String) -> RequestDraft {
        var request = RequestDraft()
        request.url = url
        return request
    }
    func testCertificateBundlesAndOptionBoundsRejectAmbiguity() throws {
        let ca = try file("ca.pem")
        let der = try file("ca.der")
        let tls = try FileTLSConfiguration(caCertificates: ca)
        XCTAssertEqual(tls.profile.anchors, [der])
        XCTAssertFalse(tls.profile.includeSystemRoots)
        let bundle = try FileTLSConfiguration(
            caCertificates: ca + file("server.pem"), includeSystemRoots: true)
        XCTAssertEqual(bundle.profile.anchors.count, 2)
        XCTAssertTrue(bundle.profile.includeSystemRoots)
        XCTAssertThrowsError(
            try FileTLSConfiguration(caCertificates: ca + Data("private-trailing-data".utf8)))
        XCTAssertThrowsError(
            try FileTLSConfiguration(caCertificates: Data(repeating: 0, count: 1024 * 1024 + 1)))
        XCTAssertThrowsError(try FileTLSConfiguration(caCertificates: Data()))
        XCTAssertThrowsError(try FileTLSConfiguration(caCertificates: ca, insecure: true))
        XCTAssertThrowsError(try FileTLSConfiguration(includeSystemRoots: true))
        XCTAssertThrowsError(try FileTLSConfiguration(clientCertificate: file("client.pem")))
        XCTAssertThrowsError(try FileTLSConfiguration(clientOrigin: endpoint(true)))
        XCTAssertThrowsError(
            try FileTLSConfiguration(pkcs12: file("client.p12"), passphrase: "rill-fixture"))
        XCTAssertThrowsError(
            try FileTLSConfiguration(
                pkcs12: Data(repeating: 0, count: 4 * 1024 * 1024 + 1), clientOrigin: endpoint(true)
            ))
        let many = (0..<17).reduce(into: Data()) { result, _ in result.append(ca) }
        XCTAssertThrowsError(try FileTLSConfiguration(caCertificates: many))
    }
    func testPEMAndPKCS12RemainMemoryOnlyAndValidateKeyPairAndDates() throws {
        let pem = try FileTLSConfiguration(
            clientCertificate: file("client.pem"), clientKey: file("client.key"),
            clientOrigin: endpoint(true))
        XCTAssertTrue(pem.hasClientIdentity)
        XCTAssertNil(pem.profile.identityReference)
        XCTAssertNotNil(pem.credential(for: URL(string: try endpoint(true))))
        XCTAssertNil(pem.credential(for: URL(string: try endpoint())))
        let p12 = try FileTLSConfiguration(
            pkcs12: file("client.p12"), passphrase: "rill-fixture", clientOrigin: endpoint(true))
        XCTAssertTrue(p12.hasClientIdentity)
        XCTAssertNil(p12.profile.identityReference)
        for (certificate, key) in [
            ("client.pem", "server.key"), ("client.pem", "ec-client.key"),
            ("ec-client.pem", "client.key"),
        ] {
            XCTAssertThrowsError(
                try FileTLSConfiguration(
                    clientCertificate: file(certificate), clientKey: file(key),
                    clientOrigin: endpoint(true))
            ) { error in
                guard case FileTLSError.invalidIdentity = error else {
                    return XCTFail("Mismatched key pair returned an unexpected error")
                }
            }
        }
        XCTAssertThrowsError(
            try FileTLSConfiguration(
                pkcs12: file("client.p12"), passphrase: "private-wrong-passphrase",
                clientOrigin: endpoint(true)))
        XCTAssertThrowsError(
            try FileTLSConfiguration(
                clientCertificate: file("client.pem"),
                clientKey: Data(
                    "-----BEGIN ENCRYPTED PRIVATE KEY-----\nprivate\n-----END ENCRYPTED PRIVATE KEY-----"
                        .utf8), clientOrigin: endpoint(true)))
        let certificate = try XCTUnwrap(FileTLSConfiguration.certificates(file("client.pem")).first)
        XCTAssertThrowsError(
            try FileTLSConfiguration.validateClientCertificate(certificate, now: .distantFuture))
        XCTAssertThrowsError(
            try FileTLSConfiguration.validateClientCertificate(certificate, now: .distantPast))
    }
    func testPublicKeyValidationRejectsUnrelatedECKeyOnSameCurve() throws {
        let certificate = try XCTUnwrap(
            FileTLSConfiguration.certificates(file("ec-client.pem")).first)
        let key = try XCTUnwrap(
            SecKeyCreateRandomKey(
                [kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeySizeInBits: 256]
                    as CFDictionary, nil))
        XCTAssertThrowsError(try FileTLSConfiguration.validateKeyPair(certificate, privateKey: key))
        {
            error in
            guard case FileTLSError.invalidIdentity = error else {
                return XCTFail("Unrelated EC key returned an unexpected error")
            }
        }
    }
    func testOriginsAreExactAndChallengesCannotSwitchHostPortOrProtocol() throws {
        let origin = try endpoint(true)
        let certificate = try file("client.pem")
        let key = try file("client.key")
        for invalid in [
            "localhost", "http://localhost:18751", origin + "/path", origin + "?q=x",
            origin + "#fragment", "https://u:p@localhost:18751", "https://localhost:0",
            "https://[]",
        ] {
            XCTAssertThrowsError(
                try FileTLSConfiguration(
                    clientCertificate: certificate, clientKey: key, clientOrigin: invalid))
        }
        let url = try XCTUnwrap(URL(string: origin))
        let space = URLProtectionSpace(
            host: "LOCALHOST", port: 18751, protocol: "https", realm: nil,
            authenticationMethod: NSURLAuthenticationMethodClientCertificate)
        XCTAssertTrue(FileTLSConfiguration.matches(space, url: url))
        for (host, port, scheme) in [
            ("elsewhere.test", 18751, "https"), ("localhost", 18750, "https"),
            ("localhost", 18751, "http"),
        ] {
            let other = URLProtectionSpace(
                host: host, port: port, protocol: scheme, realm: nil,
                authenticationMethod: NSURLAuthenticationMethodClientCertificate)
            XCTAssertFalse(FileTLSConfiguration.matches(other, url: url))
        }
    }
    func testCustomCAAndInsecureDoNotChangeSystemTrustOrHostnameChecks() async throws {
        let request = request(try endpoint() + "/json")
        let trusted = try FileTLSConfiguration(caCertificates: file("ca.pem"))
        let result = try await RequestEngine.execute(request, environment: nil, fileTLS: trusted)
        XCTAssertEqual(result.status, 200)
        let mismatch = self.request(
            request.url.replacingOccurrences(of: "localhost", with: "127.0.0.1"))
        do {
            _ = try await RequestEngine.execute(mismatch, environment: nil, fileTLS: trusted)
            XCTFail("Hostname mismatch accepted")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .serverCertificateUntrusted)
        }
        let insecure = try FileTLSConfiguration(insecure: true)
        let development = try await RequestEngine.execute(
            mismatch, environment: nil, fileTLS: insecure)
        XCTAssertEqual(development.status, 200)
        do {
            _ = try await RequestEngine.execute(request, environment: nil)
            XCTFail("System trust was changed")
        } catch {}
    }
    func testMutualTLSChainsSucceedAndIdentityNeverAppliesToAnotherOrigin() async throws {
        let origin = try endpoint(true)
        let ca = try file("ca.pem")
        let request = request(origin + "/json")
        for (certificate, key) in [
            ("client.pem", "client.key"), ("client-bundle.pem", "client.key"),
            ("ec-client.pem", "ec-client.key"),
        ] {
            let tls = try FileTLSConfiguration(
                caCertificates: ca,
                clientCertificate: file(certificate),
                clientKey: file(key), clientOrigin: origin)
            let result = try await RequestEngine.execute(request, environment: nil, fileTLS: tls)
            XCTAssertEqual(result.status, 200)
        }
        let p12 = try FileTLSConfiguration(
            caCertificates: ca, pkcs12: file("chained-client.p12"), passphrase: "rill-fixture",
            clientOrigin: origin)
        let result = try await RequestEngine.execute(request, environment: nil, fileTLS: p12)
        XCTAssertEqual(result.status, 200)
        let wrongOrigin = try FileTLSConfiguration(
            caCertificates: ca, clientCertificate: file("client.pem"),
            clientKey: file("client.key"), clientOrigin: endpoint())
        do {
            _ = try await RequestEngine.execute(request, environment: nil, fileTLS: wrongOrigin)
            XCTFail("Identity sent to a different port")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .clientCertificateRequired)
        }
        let noHostnameCheck = try FileTLSConfiguration(
            clientCertificate: file("client.pem"),
            clientKey: file("client.key"), clientOrigin: origin, insecure: true)
        let differentHost = self.request(
            request.url.replacingOccurrences(of: "localhost", with: "127.0.0.1"))
        do {
            _ = try await RequestEngine.execute(
                differentHost, environment: nil, fileTLS: noHostnameCheck)
            XCTFail("Insecure trust relaxed the client identity origin")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .clientCertificateRequired)
        }
        let untrusted = try FileTLSConfiguration(
            pkcs12: file("client.p12"), passphrase: "rill-fixture", clientOrigin: origin)
        do {
            _ = try await RequestEngine.execute(request, environment: nil, fileTLS: untrusted)
            XCTFail("Client chain implicitly trusted the server")
        } catch {}
    }
    func testTLSRedirectsStayWithinOriginalOrigin() async throws {
        let tls = try FileTLSConfiguration(
            caCertificates: file("ca.pem"), clientCertificate: file("client.pem"),
            clientKey: file("client.key"), clientOrigin: endpoint(true))
        let same = try await RequestEngine.execute(
            request(try endpoint(true) + "/redirect-same"), environment: nil, fileTLS: tls)
        XCTAssertEqual(same.status, 200)
        let cross = try await RequestEngine.execute(
            request(try endpoint() + "/redirect-cross"), environment: nil, fileTLS: tls)
        XCTAssertEqual(cross.status, 302)
    }
    func testClientFilesPreserveNativeTrustWithoutReadingSavedIdentity() async throws {
        let origin = try endpoint(true)
        let clientOnly = try FileTLSConfiguration(
            clientCertificate: file("client.pem"), clientKey: file("client.key"),
            clientOrigin: origin)
        XCTAssertFalse(clientOnly.overridesTrust)
        var trust = TLSProfile()
        trust.mode = .custom
        trust.anchors = [try file("ca.der")]
        trust.includeSystemRoots = false
        trust.identityReference = Data("must-not-resolve".utf8)
        var draft = request(origin + "/json")
        draft.tlsProfileID = trust.id
        let result = try await RequestEngine.execute(
            draft, environment: nil, tlsProfiles: [trust], identities: RejectFileTLSLookups(),
            fileTLS: clientOnly)
        XCTAssertEqual(result.status, 200)
        trust.identityReference = nil
        trust.requiresClientIdentity = true
        var native = Workspace()
        native.requests = [draft]
        native.tlsProfiles = [trust]
        let plan = try NativeFileRun.prepare(
            workspace: WorkspaceFile.encode(native), fileTLS: clientOnly)
        let nativeResult = try await plan.run(configuration: RunConfiguration())
        XCTAssertTrue(nativeResult.passed)
        let wrongDestination = request(try endpoint() + "/json")
        var required = wrongDestination
        required.tlsProfileID = trust.id
        do {
            _ = try await RequestEngine.execute(
                required, environment: nil, tlsProfiles: [trust], fileTLS: clientOnly)
            XCTFail("Required native identity was silently omitted outside its origin")
        } catch FileTLSError.invalidOrigin {}
        trust.mode = .insecure
        var workspace = Workspace()
        workspace.requests = [draft]
        workspace.tlsProfiles = [trust]
        XCTAssertThrowsError(
            try NativeFileRun.prepare(
                workspace: WorkspaceFile.encode(workspace), fileTLS: clientOnly))
        XCTAssertEqual(
            try NativeFileRun.prepare(
                workspace: WorkspaceFile.encode(workspace), allowInsecure: true, fileTLS: clientOnly
            ).requests.count, 1)
    }
    func testCancelledTLSPreparationStopsBeforeParsing() async throws {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try FileTLSConfiguration(pkcs12: Data(), clientOrigin: "https://localhost")
        }
        do {
            _ = try await task.value
            XCTFail("Cancelled input accepted")
        } catch is CancellationError {}
    }
}
