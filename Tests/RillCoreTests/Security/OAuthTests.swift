import XCTest
@testable import RillCore

@MainActor final class OAuthTests: XCTestCase {
    func testPKCES256KnownVectorAndRandomSessionIndependence() throws {
        let known = PKCEChallenge(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk", state: "state")
        XCTAssertEqual(known.challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let first = try PKCEChallenge(), second = try PKCEChallenge()
        XCTAssertEqual(first.verifier.count, 43); XCTAssertEqual(first.state.count, 43)
        XCTAssertNotEqual(first.verifier, second.verifier); XCTAssertNotEqual(first.state, second.state)
    }
    func testAuthorizationURLReplacesReservedParametersAndIncludesOnlyChallenge() throws {
        var configuration = OAuthConfiguration(); configuration.authorizationEndpoint = "https://example.test/auth?state=old&extra=1"; configuration.clientID = "client+ id"; configuration.scope = "read write"
        let pkce = try PKCEChallenge(), redirect = URL(string: "http://127.0.0.1:1234/oauth/callback")!
        let url = try OAuthClient.authorizationURL(configuration: configuration, redirect: redirect, pkce: pkce)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(items.filter { $0.name == "state" }.map(\.value), [pkce.state])
        XCTAssertEqual(items.first { $0.name == "code_challenge_method" }?.value, "S256")
        XCTAssertEqual(items.first { $0.name == "redirect_uri" }?.value, redirect.absoluteString)
        XCTAssertFalse(url.absoluteString.contains(pkce.verifier))
        configuration.authorizationEndpoint = "http://example.test/auth"
        XCTAssertThrowsError(try OAuthClient.authorizationURL(configuration: configuration, redirect: redirect, pkce: pkce))
    }
    func testCallbackStateDuplicatesErrorsAndPlusEncoding() throws {
        let redirect = URL(string: "http://127.0.0.1:1234/oauth/callback")!
        XCTAssertEqual(try OAuthClient.callbackCode(target: "/oauth/callback?state=expected&code=a%2Bb+c", redirect: redirect, expectedState: "expected"), "a+b c")
        for target in ["/other?state=expected&code=x", "/oauth/callback?state=wrong&code=x", "/oauth/callback?state=expected&state=expected&code=x", "/oauth/callback?state=expected&code=x&code=y", "/oauth/callback?state=expected", "//evil.test/oauth/callback?state=expected&code=x"] {
            XCTAssertThrowsError(try OAuthClient.callbackCode(target: target, redirect: redirect, expectedState: "expected"))
        }
        XCTAssertThrowsError(try OAuthClient.callbackCode(target: "/oauth/callback?state=expected&error=access_denied", redirect: redirect, expectedState: "expected")) { XCTAssertEqual($0 as? OAuthError, .denied) }
    }
    func testClientCredentialsAndPKCETokenRequestEncoding() throws {
        var configuration = OAuthConfiguration(); configuration.tokenEndpoint = "https://example.test/token"; configuration.clientID = "client:id"; configuration.clientAuthentication = .basic; configuration.scope = "read write"
        let request = try OAuthClient.tokenRequest(configuration: configuration, secret: "secret+value")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Basic " + Data("client%3Aid:secret%2Bvalue".utf8).base64EncodedString())
        XCTAssertEqual(String(data: request.httpBody!, encoding: .utf8), "grant_type=client_credentials&scope=read+write")
        configuration.clientAuthentication = .none
        XCTAssertThrowsError(try OAuthClient.tokenRequest(configuration: configuration, secret: nil))
        let pkce = try PKCEChallenge()
        let codeRequest = try OAuthClient.tokenRequest(configuration: configuration, secret: nil, code: "code+", redirect: URL(string: "http://127.0.0.1:1234/oauth/callback"), verifier: pkce.verifier)
        let form = String(decoding: codeRequest.httpBody!, as: UTF8.self)
        XCTAssertTrue(form.contains("code=code%2B")); XCTAssertTrue(form.contains("code_verifier=" + pkce.verifier)); XCTAssertTrue(form.contains("client_id=client%3Aid"))
    }
    func testTokenValidationExpiryAndGenericErrors() throws {
        let now = Date(timeIntervalSince1970: 100)
        let token = try OAuthClient.decodeToken(Data(#"{"access_token":"valid-token","token_type":"Bearer","expires_in":1}"#.utf8), status: 200, now: now)
        XCTAssertEqual(token.expiresAt, now.addingTimeInterval(1))
        for json in [#"{"access_token":"bad token","token_type":"Bearer"}"#, #"{"access_token":"token","token_type":"MAC"}"#, #"{"access_token":"token","token_type":"Bearer","expires_in":true}"#, #"{"access_token":"token","token_type":"Bearer","expires_in":-1}"#] {
            XCTAssertThrowsError(try OAuthClient.decodeToken(Data(json.utf8), status: 200))
        }
        XCTAssertThrowsError(try OAuthClient.decodeToken(Data(#"{"error_description":"SEEDED_SECRET"}"#.utf8), status: 400)) { XCTAssertFalse($0.localizedDescription.contains("SEEDED_SECRET")) }
        XCTAssertThrowsError(try OAuthClient.decodeToken(Data(repeating: 32, count: 65_537), status: 200))
    }
    func testTemporaryLoopbackListenerAcceptsOneCallbackAndCloses() async throws {
        let receiver = OAuthCallbackReceiver(expectedState: "expected")
        let redirect = try await receiver.start()
        XCTAssertEqual(redirect.host, "127.0.0.1")
        let waiting = Task { try await receiver.waitForCode(timeout: .seconds(3)) }
        let callback = URL(string: redirect.absoluteString + "?state=expected&code=fixture-code")!
        let (body, response) = try await URLSession.shared.data(from: callback)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertFalse(String(decoding: body, as: UTF8.self).contains("fixture-code"))
        let code = try await waiting.value
        XCTAssertEqual(code, "fixture-code")
        await receiver.stop()
        do { _ = try await URLSession.shared.data(from: redirect); XCTFail("Listener remained open") } catch { }
    }
    func testListenerCancellationAndTimeoutReleaseWaiter() async throws {
        let receiver = OAuthCallbackReceiver(expectedState: "state"); _ = try await receiver.start()
        let waiting = Task { try await receiver.waitForCode() }; waiting.cancel()
        do { _ = try await waiting.value; XCTFail("Cancelled wait succeeded") } catch { }
        await receiver.stop()
        let timeout = OAuthCallbackReceiver(expectedState: "state"); _ = try await timeout.start()
        do { _ = try await timeout.waitForCode(timeout: .milliseconds(30)); XCTFail("Wait did not time out") }
        catch { XCTAssertEqual(error as? OAuthError, .timedOut) }
    }
    func testExpiredOAuthProfileFailsBeforePreparation() throws {
        var profile = AuthenticationProfile(); profile.oauth = OAuthConfiguration(); profile.secretName = "token"; profile.tokenExpiresAt = .distantPast
        var request = RequestDraft(); request.url = "https://example.test"; request.authProfileID = profile.id
        XCTAssertThrowsError(try RequestEngine.prepare(request, environment: nil, profiles: [profile])) { XCTAssertTrue($0.localizedDescription.contains("expired")) }
    }
    func testRealTokenEndpointClientCredentialsAndPKCEExchange() async throws {
        let base = try XCTUnwrap(ProcessInfo.processInfo.environment["RILL_TEST_BASE_URL"])
        var configuration = OAuthConfiguration(); configuration.tokenEndpoint = base + "/oauth/token"; configuration.clientID = "fixture-client"; configuration.clientAuthentication = .basic; configuration.clientSecretName = "client"
        let secrets = NamedSecretResolver(catalog: [], processEnvironment: ["RILL_SECRET_CLIENT": "fixture-secret"])
        let token = try await OAuthClient.acquire(configuration: configuration, secrets: secrets)
        XCTAssertEqual(token.accessToken, "fixture-access-token"); XCTAssertNotNil(token.expiresAt)
        configuration.clientAuthentication = .none
        let pkce = PKCEChallenge(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk", state: "state")
        let codeToken = try await OAuthClient.acquire(configuration: configuration, secrets: secrets, code: "fixture-code", redirect: URL(string: "http://127.0.0.1:1234/oauth/callback"), verifier: pkce.verifier)
        XCTAssertEqual(codeToken.accessToken, "fixture-access-token")
    }
    func testTokenEndpointRejectsRedirectOversizeAndProviderErrorsWithoutLeakingContent() async throws {
        let base = try XCTUnwrap(ProcessInfo.processInfo.environment["RILL_TEST_BASE_URL"])
        var configuration = OAuthConfiguration(); configuration.clientID = "fixture-client"; configuration.clientAuthentication = .body
        for path in ["/oauth/token", "/oauth/redirect", "/oauth/oversized"] {
            configuration.tokenEndpoint = base + path
            let request = try OAuthClient.tokenRequest(configuration: configuration, secret: "wrong-secret")
            do { _ = try await OAuthClient.acquire(request); XCTFail("Invalid token exchange succeeded") }
            catch { XCTAssertFalse(error.localizedDescription.contains("SEEDED_SECRET")); XCTAssertFalse(error.localizedDescription.contains("wrong-secret")) }
        }
    }

}
