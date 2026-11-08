import Foundation
import RillCore

struct RequestSessionOptions {
    let session: URL
    let key: URL

    init?(_ args: Arguments, protected: [URL]) throws {
        let session = args.value("session")
        let key = args.value("session-key-file")
        if session == nil && key == nil { return nil }
        guard let session, let key, !session.isEmpty, !key.isEmpty,
            !session.contains("\0"), !key.contains("\0"),
            !args.flags.contains("insecure"), !args.flags.contains("allow-insecure")
        else {
            throw CLIError.usage(
                "Use --session FILE with --session-key-file FILE and verified TLS settings.")
        }
        let sessionURL = URL(fileURLWithPath: session).standardizedFileURL
        let keyURL = URL(fileURLWithPath: key).standardizedFileURL
        let lock = sessionURL.appendingPathExtension("lock")
        let paths = [sessionURL, keyURL, lock]
        for (index, path) in paths.enumerated() {
            let others = Array(paths.dropFirst(index + 1)) + protected
            guard !others.contains(where: { Self.aliases($0, path) }) else {
                throw CLIError.usage(
                    "Session, lock and key paths must be distinct from workspace, request inputs and output."
                )
            }
        }
        self.session = sessionURL
        self.key = keyURL
    }

    private static func aliases(_ left: URL, _ right: URL) -> Bool {
        let left = left.resolvingSymlinksInPath()
        let right = right.resolvingSymlinksInPath()
        if left == right { return true }
        guard
            let identity = try? left.resourceValues(forKeys: [.fileResourceIdentifierKey])
                .fileResourceIdentifier as? NSObject,
            let other = try? right.resourceValues(forKeys: [.fileResourceIdentifierKey])
                .fileResourceIdentifier
        else { return false }
        return identity.isEqual(other)
    }

    func open() throws -> PersistentCookieSession {
        do {
            return try PersistentCookieSession(file: session, keyFile: key)
        } catch is CancellationError {
            throw CancellationError()
        } catch CookieSessionError.busy {
            throw CLIError.usage(
                "The cookie session is in use by another invocation. No request sent.")
        } catch {
            throw CLIError.usage(
                "Could not open the cookie session. Check the key, format and private file permissions. No request sent."
            )
        }
    }
}
