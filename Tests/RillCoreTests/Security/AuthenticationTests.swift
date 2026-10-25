import XCTest
@testable import RillCore

@MainActor final class AuthenticationTests: XCTestCase {
    func testNativeProviderPrecedenceAndMissingOrDeniedKeyNeverFallsBack() throws {
        let native = NamedSecret(name: "api.token"), store = TestCredentials()
        try store.write("native-value", id: native.id)
        let environment = ["RILL_SECRET_API_TOKEN": "process-value"]
        XCTAssertEqual(try NamedSecretResolver(catalog: [native], credentials: store, processEnvironment: environment).resolve("api.token"), "native-value")
        try store.write("", id: native.id)
        XCTAssertThrowsError(try NamedSecretResolver(catalog: [native], credentials: store, processEnvironment: environment).resolve("api.token"))
        store.failures(read: true)
        XCTAssertThrowsError(try NamedSecretResolver(catalog: [native], credentials: store, processEnvironment: environment).resolve("api.token"))
        XCTAssertEqual(try NamedSecretResolver(catalog: [], credentials: store, processEnvironment: environment).resolve("api.token"), "process-value")
    }
    func testProcessNamesNormalizeAndInvalidNamesAreRejected() throws {
        XCTAssertEqual(try NamedSecretResolver.environmentKey(for: "service.api-token"), "RILL_SECRET_SERVICE_API_TOKEN")
        for name in ["", "space name", "\n", "é", String(repeating: "x", count: 129)] { XCTAssertThrowsError(try NamedSecretResolver.validateName(name)) }
        XCTAssertThrowsError(try NamedSecretResolver(catalog: [], processEnvironment: [:]).resolve("absent"))
    }
    func testSecretValuesAreOpaqueAndFreezeOnFirstUseWithoutChangingSavedEnvironment() throws {
        let secret = NamedSecret(name: "token"), store = TestCredentials()
        try store.write("opaque{{not-a-variable}}", id: secret.id)
        let resolver = NamedSecretResolver(catalog: [secret], credentials: store, processEnvironment: [:])
        var environment = Environment(name: "Test"); environment.variables = [Field(name: "auth", value: "{{secret:token}}")]
        var draft = RequestDraft(); draft.url = "https://example.test"; draft.auth = .bearer; draft.credential = "{{auth}}"
        let prepared = try RequestEngine.prepare(draft, environment: environment, secrets: resolver)
        XCTAssertEqual(prepared.value(forHTTPHeaderField: "Authorization"), "Bearer opaque{{not-a-variable}}")
        try store.write("changed", id: secret.id)
        XCTAssertEqual(try resolver.resolve("token"), "opaque{{not-a-variable}}")
        XCTAssertEqual(environment.variables[0].value, "{{secret:token}}")
    }
    func testProfileSelectionOverridesRequestAndMissingProfileOrSecretFails() throws {
        var profile = AuthenticationProfile(); profile.kind = .apiKey; profile.apiKeyName = "X-Key"; profile.secretName = "profile"
        var draft = RequestDraft(); draft.url = "https://example.test"; draft.auth = .bearer; draft.credential = "inactive"; draft.authProfileID = profile.id
        let provider = NamedSecretResolver(catalog: [], processEnvironment: ["RILL_SECRET_PROFILE": "profile-key"])
        let prepared = try RequestEngine.prepare(draft, environment: nil, profiles: [profile], secrets: provider)
        XCTAssertEqual(prepared.value(forHTTPHeaderField: "X-Key"), "profile-key"); XCTAssertNil(prepared.value(forHTTPHeaderField: "Authorization"))
        XCTAssertThrowsError(try RequestEngine.prepare(draft, environment: nil, profiles: [], secrets: provider))
        XCTAssertThrowsError(try RequestEngine.prepare(draft, environment: nil, profiles: [profile], secrets: NamedSecretResolver(catalog: [], processEnvironment: [:])))
    }
    func testVaultCRUDAndProfileWorkspaceNeverSerializeValues() async throws {
        let store = TestCredentials(), secret = NamedSecret(name: "token")
        let vault = NamedSecretVault(credentials: store)
        try await vault.set("SEEDED_NATIVE_SECRET", for: secret)
        XCTAssertEqual(try store.read(secret.id), "SEEDED_NATIVE_SECRET")
        var workspace = Workspace(); workspace.namedSecrets = [secret]
        var profile = AuthenticationProfile(); profile.secretName = "token"; workspace.authProfiles = [profile]
        let encoded = try WorkspaceFile.encode(workspace)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("SEEDED_NATIVE_SECRET"))
        XCTAssertFalse(String(decoding: try WorkspaceBackup.encode(workspace: workspace, editor: nil), as: UTF8.self).contains("SEEDED_NATIVE_SECRET"))
        try await vault.delete(secret); XCTAssertEqual(try store.read(secret.id), "")
    }
    func testImportRemapsProfilesAndCollidingSecretNamesWithoutBindingExistingKeys() throws {
        var existing = Workspace(); existing.namedSecrets = [NamedSecret(name: "token")]
        var incoming = Workspace(); incoming.namedSecrets = [NamedSecret(name: "token")]
        var profile = AuthenticationProfile(); profile.secretName = "token"; incoming.authProfiles = [profile]
        var request = RequestDraft(); request.authProfileID = profile.id; request.url = "https://example.test"; request.headers = [Field(name: "X-Token", value: "{{secret:token}}")]; incoming.requests = [request]
        var environment = Environment(name: "Test"); environment.variables = [Field(name: "token", value: "{{secret:token}}")]; incoming.environments = [environment]
        let merged = try WorkspaceImport.merging(incoming, into: existing)
        XCTAssertNotEqual(merged.authProfiles![0].id, profile.id)
        XCTAssertEqual(merged.requests[0].authProfileID, merged.authProfiles![0].id)
        let importedName = merged.namedSecrets![1].name
        XCTAssertNotEqual(importedName, "token"); XCTAssertNotEqual(merged.namedSecrets![1].id, incoming.namedSecrets![0].id)
        XCTAssertEqual(merged.authProfiles![0].secretName, importedName)
        XCTAssertEqual(merged.requests[0].headers[0].value, "{{secret:\(importedName)}}")
        XCTAssertEqual(merged.environments[0].variables[0].value, "{{secret:\(importedName)}}")
    }
    func testCollidingNormalizedCatalogNamesAreRejected() throws {
        var workspace = Workspace(); workspace.namedSecrets = [NamedSecret(name: "api.token"), NamedSecret(name: "API-TOKEN")]
        XCTAssertThrowsError(try WorkspaceFile.validate(workspace))
    }
}
