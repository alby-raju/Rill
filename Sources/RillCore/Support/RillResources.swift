import Foundation

/// Relocatable app/SwiftPM resource lookup without the generated accessor's fatal fallback.
public enum RillResources {
    public static func url(
        forResource name: String, withExtension ext: String, bundle: Bundle = .main
    ) -> URL? {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        guard !name.isEmpty, !ext.isEmpty,
            [name, ext].allSatisfy({ $0.unicodeScalars.allSatisfy(allowed.contains) })
        else { return nil }
        if let direct = bundle.url(forResource: name, withExtension: ext) { return direct }
        let roots = [
            bundle.resourceURL, bundle.bundleURL, bundle.executableURL?.deletingLastPathComponent(),
        ]
        .compactMap { $0 }
        for root in roots {
            let resourceBundle = root.appendingPathComponent("Rill_Rill.bundle", isDirectory: true)
            for directory in [
                resourceBundle, resourceBundle.appendingPathComponent("Contents/Resources"),
            ] {
                let candidate = directory.appendingPathComponent(name).appendingPathExtension(ext)
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(
                    atPath: candidate.path, isDirectory: &isDirectory), !isDirectory.boolValue
                {
                    return candidate
                }
            }
        }
        return nil
    }
}
