import Foundation

/// Resolves `CFBundleIdentifier` from an executable path inside a `.app`
/// bundle, caching by app-bundle path so helpers that share one `.app` do not
/// re-read `Info.plist` on every first sighting.
///
/// Non-`.app` paths return nil without touching the filesystem.
public struct BundleIDCache {
    private var cache: [String: String?] = [:]
    private let readPlist: (String) -> String?

    public init(
        readPlist: @escaping (String) -> String? = BundleIDCache.readBundleID(fromAppBundle:)
    ) {
        self.readPlist = readPlist
    }

    /// Derive a best-effort bundle identifier from an executable path.
    public mutating func bundleID(fromExecutablePath path: String?) -> String? {
        guard let path, let appBundlePath = Self.appBundlePath(fromExecutablePath: path) else {
            return nil
        }
        if let entry = cache.index(forKey: appBundlePath) {
            return cache[entry].value
        }
        let id = readPlist(appBundlePath)
        cache[appBundlePath] = id
        return id
    }

    public mutating func removeAll() {
        cache.removeAll(keepingCapacity: true)
    }

    /// `.../Foo.app/Contents/MacOS/Foo` -> `.../Foo.app`. Nil when not inside a bundle.
    public static func appBundlePath(fromExecutablePath path: String) -> String? {
        guard let appRange = path.range(of: ".app/Contents/MacOS/") else { return nil }
        return String(path[..<appRange.lowerBound]) + ".app"
    }

    /// Read `CFBundleIdentifier` from `<app>/Contents/Info.plist`.
    public static func readBundleID(fromAppBundle appBundlePath: String) -> String? {
        let infoPlist = appBundlePath + "/Contents/Info.plist"
        guard let data = FileManager.default.contents(atPath: infoPlist),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
            let dict = plist as? [String: Any],
            let bundleID = dict["CFBundleIdentifier"] as? String
        else { return nil }
        return bundleID
    }
}
