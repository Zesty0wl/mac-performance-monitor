import Foundation

/// Resolves `CFBundleIdentifier` from an executable path inside a `.app`
/// bundle, caching by app-bundle path so helpers that share one `.app` do not
/// re-read `Info.plist` on every first sighting.
///
/// Non-`.app` paths return nil without touching the filesystem.
public struct BundleIDCache {
    private var cache = BoundedCache<String, String?>()
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
        if let entry = cache.value(forKey: appBundlePath) {
            return entry
        }
        let id = readPlist(appBundlePath)
        cache.insert(id, forKey: appBundlePath)
        return id
    }

    public mutating func removeAll() {
        cache.removeAll()
    }

    /// `.../Foo.app/Contents/MacOS/Foo` -> `.../Foo.app`. Nil when not inside a bundle.
    public static func appBundlePath(fromExecutablePath path: String) -> String? {
        guard let appRange = path.range(of: ".app/Contents/MacOS/") else { return nil }
        return String(path[..<appRange.lowerBound]) + ".app"
    }

    /// Read `CFBundleIdentifier` from `<app>/Contents/Info.plist`.
    public static func readBundleID(fromAppBundle appBundlePath: String) -> String? {
        readInfoPlist(ofAppBundle: appBundlePath)?["CFBundleIdentifier"] as? String
    }

    /// `<app>/Contents/Info.plist` as a dictionary. The bundle belongs to
    /// whichever process we sampled, so only a regular file of at most
    /// `maxBytes` is read: a huge (or sparse) plist or a FIFO planted there
    /// must not balloon our memory or block the caller.
    public static func readInfoPlist(
        ofAppBundle appBundlePath: String, maxBytes: Int = 1 << 20
    ) -> [String: Any]? {
        let fd = open(appBundlePath + "/Contents/Info.plist", O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG,
            st.st_size > 0, st.st_size <= off_t(maxBytes)
        else { return nil }
        let size = Int(st.st_size)
        var data = Data(count: size)
        let n = data.withUnsafeMutableBytes { read(fd, $0.baseAddress, size) }
        guard n == size else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil))
            as? [String: Any]
    }
}
