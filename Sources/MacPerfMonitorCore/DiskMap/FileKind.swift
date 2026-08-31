// SPDX-License-Identifier: MIT

import Foundation

/// The coarse category the Disk Map colours and groups by. Files are
/// classified by extension at scan time from a static table (no `UTType`
/// lookups on the hot path: three million entries cannot afford one each), so
/// the categories are deliberately broad and the table small. Raw values are
/// persisted in snapshots; append new cases, never renumber.
public enum FileKind: UInt8, Sendable, CaseIterable, Codable {
    /// A plain directory. Packages take the kind of their extension instead.
    case folder = 0
    case application = 1
    case video = 2
    case image = 3
    case audio = 4
    /// Archives and disk images: zip, dmg, iso, sparsebundle, ...
    case archive = 5
    case document = 6
    /// Source, build products, dependency stores, developer tooling.
    case code = 7
    /// Databases, virtual machine disks, container images, datasets.
    case data = 8
    /// Logs, caches, crash reports: content that regenerates.
    case cache = 9
    case system = 10
    case other = 11

    public var label: String {
        switch self {
        case .folder: return "Folder"
        case .application: return "Applications"
        case .video: return "Video"
        case .image: return "Images"
        case .audio: return "Audio"
        case .archive: return "Archives and disk images"
        case .document: return "Documents"
        case .code: return "Code and developer"
        case .data: return "Data and databases"
        case .cache: return "Logs and caches"
        case .system: return "System"
        case .other: return "Other"
        }
    }

    /// The order the Kinds view and legends list categories in.
    public static let displayOrder: [FileKind] = [
        .application, .video, .image, .audio, .archive, .document, .code, .data, .cache,
        .system, .other,
    ]
}

/// Extension tables for kind classification and package detection. Lookups
/// are allocation-free: an extension of up to sixteen ASCII bytes is packed
/// into a two-word key, lower-cased on the way in. Longer extensions fall to
/// `.other`, except the handful of long package extensions, which go through
/// a small string table because directories are rare enough to afford it.
public enum FileKindClassifier {
    /// Classify a file by its name. `isDirectory` selects the package table;
    /// a directory whose extension is not a package extension is `.folder`.
    public static func kind(forName name: String, isDirectory: Bool) -> FileKind {
        var bytes = Array(name.utf8)
        return bytes.withUnsafeMutableBufferPointer {
            kind(forNameBytes: $0, isDirectory: isDirectory)
        }
    }

    /// Byte-level entry point used by the scanner on raw listing names.
    static func kind(
        forNameBytes name: UnsafeMutableBufferPointer<UInt8>, isDirectory: Bool
    )
        -> FileKind
    {
        kind(forNameBytes: UnsafeBufferPointer(name), isDirectory: isDirectory)
    }

    static func kind(forNameBytes name: UnsafeBufferPointer<UInt8>, isDirectory: Bool) -> FileKind {
        guard let dot = lastDot(in: name), dot + 1 < name.count else {
            return isDirectory ? .folder : .other
        }
        let extensionLength = name.count - dot - 1
        if isDirectory {
            guard extensionLength <= maximumPackageExtensionLength else { return .folder }
            var chars = [UInt8](repeating: 0, count: extensionLength)
            for i in 0..<extensionLength { chars[i] = lowercased(name[dot + 1 + i]) }
            let key = String(decoding: chars, as: UTF8.self)
            return packages[key] ?? .folder
        }
        guard let key = packedKey(name, from: dot + 1) else { return .other }
        return files[key] ?? .other
    }

    /// True when a directory with this name is a package the map should treat
    /// as a leaf (an app, a library bundle, a project).
    public static func isPackage(name: String) -> Bool {
        kind(forName: name, isDirectory: true) != .folder
    }

    static func isPackage(nameBytes name: UnsafeBufferPointer<UInt8>) -> Bool {
        kind(forNameBytes: name, isDirectory: true) != .folder
    }

    // MARK: - Tables

    private static let maximumPackageExtensionLength = 16

    /// Directory extensions that mean "package". Value is the kind the package
    /// counts as in the Kinds view.
    private static let packages: [String: FileKind] = [
        "app": .application, "appex": .application, "xpc": .application,
        "plugin": .application, "bundle": .application, "kext": .application,
        "framework": .application, "prefpane": .application, "saver": .application,
        "qlgenerator": .application, "mdimporter": .application, "wdgt": .application,
        "action": .application, "workflow": .application, "docset": .code,
        "playground": .code, "xcodeproj": .code, "xcworkspace": .code, "xcarchive": .code,
        "xcappdata": .code, "xctest": .code, "swiftpm": .code,
        "photoslibrary": .image, "aplibrary": .image, "musiclibrary": .audio,
        "tvlibrary": .video, "imovielibrary": .video, "fcpbundle": .video, "logicx": .audio,
        "band": .audio, "mpkg": .archive, "sparsebundle": .archive, "rtfd": .document,
        "scptd": .code, "vmwarevm": .data, "pvm": .data, "utm": .data, "key": .document,
        "pages": .document, "numbers": .document, "download": .other,
        "textclipping": .document, "lproj": .system, "nib": .system, "storyboardc": .system,
        "abbu": .data, "iconset": .image, "xcassets": .code, "xcdatamodeld": .code,
        "lsp": .code, "mlmodelc": .data, "mlpackage": .data,
    ]

    /// Up to sixteen lower-cased ASCII bytes, big-endian across two words.
    private struct ExtensionKey: Hashable {
        var high: UInt64
        var low: UInt64
    }

    /// File extensions, packed. Built once from a readable list.
    private static let files: [ExtensionKey: FileKind] = {
        var table: [ExtensionKey: FileKind] = [:]
        func add(_ kind: FileKind, _ extensions: [String]) {
            for ext in extensions {
                var bytes = Array(ext.utf8)
                let key = bytes.withUnsafeMutableBufferPointer { buffer in
                    packedKey(UnsafeBufferPointer(buffer), from: 0)
                }
                if let key { table[key] = kind }
            }
        }
        add(
            .video,
            [
                "mp4", "m4v", "mov", "mkv", "avi", "wmv", "flv", "webm", "mpg", "mpeg", "m2ts",
                "mts", "ts", "3gp", "vob", "ogv", "mxf", "braw", "r3d", "prproj", "fcpxml",
            ])
        add(
            .image,
            [
                "jpg", "jpeg", "png", "gif", "heic", "heif", "tif", "tiff", "bmp", "webp", "raw",
                "cr2", "cr3", "nef", "arw", "dng", "orf", "raf", "rw2", "psd", "psb", "ai", "svg",
                "icns", "ico", "avif", "jxl", "eps", "sketch", "fig", "afphoto", "afdesign",
                "pxd", "pxm", "xcf",
            ])
        add(
            .audio,
            [
                "mp3", "m4a", "aac", "flac", "wav", "aif", "aiff", "ogg", "oga", "opus", "wma",
                "alac", "caf", "m4b", "m4p", "mid", "midi", "aup3", "als", "logicx",
            ])
        add(
            .archive,
            [
                "zip", "gz", "tgz", "bz2", "xz", "zst", "7z", "rar", "tar", "lz", "lzma", "dmg",
                "iso", "img", "pkg", "xip", "cpio", "sit", "sitx", "war", "jar", "aar", "whl",
                "ipsw", "ipa", "apk", "deb", "rpm", "cab", "sparseim", "toast", "cdr",
            ])
        add(
            .document,
            [
                "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "odt", "ods", "odp", "rtf",
                "txt", "md", "markdown", "epub", "mobi", "azw3", "csv", "tsv", "numbers", "pages",
                "key", "keynote", "note", "tex", "bib", "indd", "pub", "vsd", "vsdx",
            ])
        add(
            .code,
            [
                "swift", "c", "h", "m", "mm", "cpp", "cc", "cxx", "hpp", "hh", "java", "kt", "kts",
                "scala", "go", "rs", "py", "pyc", "pyo", "rb", "php", "js", "mjs", "cjs", "ts",
                "tsx", "jsx", "vue", "svelte", "html", "htm", "css", "scss", "sass", "less",
                "json", "yaml", "yml", "toml", "xml", "plist", "sh", "zsh", "bash", "fish", "pl",
                "lua", "r", "jl", "dart", "cs", "fs", "vb", "sql", "graphql", "proto", "cmake",
                "make", "mk", "gradle", "pbxproj", "xcconfig", "entitlements", "storyboard",
                "xib", "strings", "o", "a", "so", "dylib", "dsym", "wasm", "class", "node",
                "swiftmodule", "swiftdoc", "pcm", "bc", "ll", "d", "map", "lock", "gemspec",
                "podspec", "nupkg", "crate", "rlib", "rmeta", "elc", "hi", "beam", "ex", "exs",
                "erl", "clj", "hs", "ml", "nim", "zig", "v", "sv", "vhd", "ipynb",
            ])
        add(
            .data,
            [
                "sqlite", "sqlite3", "db", "db3", "sqlitedb", "realm", "mdb", "accdb", "parquet",
                "avro", "orc", "arrow", "feather", "h5", "hdf5", "npy", "npz", "pkl", "pickle",
                "pt", "pth", "ckpt", "safetensors", "gguf", "ggml", "onnx", "mlmodel", "bin",
                "dat", "vmdk", "vdi", "vhd", "vhdx", "qcow2", "qcow", "hdd", "vmem",
                "vmss", "nvram", "ova", "ovf", "tfrecord", "mat", "sav", "dta", "rdata", "rds",
                "bak", "dump", "wal", "shm", "ldb", "sst", "idx", "pack",
            ])
        add(
            .cache,
            [
                "log", "crash", "ips", "diag", "spin", "hang", "trace", "tracev3", "cache",
                "tmp", "temp", "part", "crdownload", "download", "swp", "swo", "orig", "rej",
                "old", "cachedata", "etag", "journal", "asl",
            ])
        add(
            .system,
            [
                "kext", "efi", "kernelcache", "im4p", "im4m", "img4", "aea", "asar", "car",
                "metallib", "mom", "momd", "nib", "loctable", "dylib_cache", "cryptex",
            ])
        return table
    }()

    // MARK: - Byte helpers

    private static func lastDot(in name: UnsafeBufferPointer<UInt8>) -> Int? {
        var i = name.count - 1
        while i > 0 {
            if name[i] == UInt8(ascii: ".") { return i }
            i -= 1
        }
        // A leading dot is a hidden-file marker, not an extension separator.
        return nil
    }

    @inline(__always)
    private static func lowercased(_ byte: UInt8) -> UInt8 {
        (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z")) ? byte + 32 : byte
    }

    /// Pack up to sixteen bytes, lower-cased, big-endian, into one key. Nil
    /// for anything longer or non-ASCII (those are never in the table anyway).
    /// Shorter extensions leave leading zero bytes; a file name can never
    /// contain NUL, so "a" and a hypothetical "\0a" cannot collide.
    private static func packedKey(
        _ name: UnsafeBufferPointer<UInt8>, from start: Int
    )
        -> ExtensionKey?
    {
        let length = name.count - start
        guard length >= 1, length <= 16 else { return nil }
        var high: UInt64 = 0
        var low: UInt64 = 0
        for i in 0..<length {
            let byte = name[start + i]
            guard byte < 0x80 else { return nil }
            if i < 8 {
                high = (high << 8) | UInt64(lowercased(byte))
            } else {
                low = (low << 8) | UInt64(lowercased(byte))
            }
        }
        return ExtensionKey(high: high, low: low)
    }
}
