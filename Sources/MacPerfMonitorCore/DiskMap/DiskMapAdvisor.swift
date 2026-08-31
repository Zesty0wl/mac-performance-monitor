// SPDX-License-Identifier: MIT

import Foundation

/// How safe it is to remove something, from the point of view of someone out
/// of disk space who wants to act without breaking anything.
public enum DiskMapSafetyTier: Int, Sendable, CaseIterable, Codable, Comparable {
    /// Part of macOS or protected by it: cannot or must not be removed.
    case systemProtected = 0
    /// Owned by an app that has its own way of reclaiming the space; trashing
    /// by hand risks corrupting a library or is simply the wrong tool.
    case managedByApp = 1
    /// The user's own files: fine to remove, but only after looking.
    case reviewBeforeRemoving = 2
    /// Caches, logs and build products that regenerate on demand.
    case safeToRemove = 3

    public static func < (lhs: DiskMapSafetyTier, rhs: DiskMapSafetyTier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var label: String {
        switch self {
        case .systemProtected: return "Protected by macOS"
        case .managedByApp: return "Managed by an app"
        case .reviewBeforeRemoving: return "Review before removing"
        case .safeToRemove: return "Safe to remove"
        }
    }
}

/// What the advisor says about one item.
public struct DiskMapAdvice: Sendable, Equatable {
    public var tier: DiskMapSafetyTier
    /// The rule that matched (for example "Xcode DerivedData"), or a generic
    /// name when nothing specific did.
    public var title: String
    public var reason: String
    /// The proper way to reclaim the space, when there is one.
    public var howToReclaim: String?
    /// Whether the app offers Move to Trash at all.
    public var canTrash: Bool { tier != .systemProtected }
}

/// A known location found in a scan, for the Reclaim view.
public struct DiskMapReclaimItem: Sendable, Equatable, Identifiable {
    public var id: Int32 { node }
    public var node: Int32
    public var bytes: UInt64
    public var count: UInt32
    public var advice: DiskMapAdvice
}

/// Bytes per kind with the biggest items of each, for the Kinds view. Files
/// inside a package count towards the package's kind (an app's PNGs are
/// "Applications", not "Images") and the package itself is the item listed.
public struct DiskMapKindTotal: Sendable, Equatable, Identifiable {
    public var id: FileKind { kind }
    public var kind: FileKind
    public var bytes: UInt64
    public var count: UInt64
    /// Largest items of this kind, nodes, largest first.
    public var topItems: [Int32]
}

/// Everything the advisor derives from a finished scan in one pass over the
/// arena: a safety tier per node (rules inherit down the tree), the known
/// locations for the Reclaim view, and the per-kind totals.
public struct DiskMapAnalysis: Sendable, Equatable {
    public var revision: Int
    /// `DiskMapSafetyTier` raw values, one per node.
    public var tiers: [UInt8]
    /// Index into `DiskMapAdvisor.rules` per node, or -1 when only the
    /// default advice applies.
    public var ruleIndex: [Int16]
    public var reclaim: [DiskMapReclaimItem]
    public var kinds: [DiskMapKindTotal]
    public var trashedBytes: UInt64

    public func tier(of node: Int32) -> DiskMapSafetyTier {
        DiskMapSafetyTier(rawValue: Int(tiers[Int(node)])) ?? .reviewBeforeRemoving
    }
}

/// Knows which places on a Mac are safe to clear, which belong to an app, and
/// which must be left alone, and can say why in a sentence. Paths are the
/// canonical ones (`/Users/...`, not `/System/Volumes/Data/Users/...`).
public struct DiskMapAdvisor: Sendable {
    /// One rule. `pattern` is a canonical path with `~` for the home folder;
    /// a leading `**/` matches at any depth, `*` matches one component, and
    /// `*.ext` matches a component by extension.
    public struct Rule: Sendable, Equatable {
        public var pattern: String
        public var tier: DiskMapSafetyTier
        public var title: String
        public var reason: String
        public var howToReclaim: String?
        /// The rule names a file rather than a folder.
        public var isFile: Bool
    }

    public let home: String
    public let rules: [Rule]

    public init(home: String = NSHomeDirectory(), rules: [Rule] = DiskMapAdvisor.defaultRules) {
        self.home = home.hasSuffix("/") && home.count > 1 ? String(home.dropLast()) : home
        self.rules = rules
        var exact: [String: Int] = [:]
        var byName: [String: [Int]] = [:]
        var byExtension: [String: [Int]] = [:]
        for (index, rule) in rules.enumerated() {
            let expanded =
                rule.pattern.hasPrefix("~") ? self.home + rule.pattern.dropFirst() : rule.pattern
            if expanded.hasPrefix("**/") {
                let tail = String(expanded.dropFirst(3))
                if tail.hasPrefix("*.") {
                    byExtension[String(tail.dropFirst(2)).lowercased(), default: []].append(index)
                } else {
                    byName[tail, default: []].append(index)
                }
            } else if expanded.contains("*") {
                wildcard.append((expanded.split(separator: "/").map(String.init), index))
            } else {
                exact[expanded] = index
            }
        }
        self.exactPaths = exact
        self.anyDepthNames = byName
        self.anyDepthExtensions = byExtension
    }

    private let exactPaths: [String: Int]
    private let anyDepthNames: [String: [Int]]
    private let anyDepthExtensions: [String: [Int]]
    private var wildcard: [(components: [String], rule: Int)] = []

    // MARK: - Single items

    /// Advice for one canonical path, considering its own flags and the rule
    /// that matches it or its nearest matching ancestor.
    public func advice(
        forCanonicalPath path: String, isDirectory: Bool, flags: FileNodeFlags
    )
        -> DiskMapAdvice
    {
        if let override = flagAdvice(flags) { return override }
        var components = path.split(separator: "/").map(String.init)
        var isDir = isDirectory
        while true {
            if let index = match(components: components, isDirectory: isDir) {
                return advice(for: rules[index])
            }
            guard !components.isEmpty else { break }
            components.removeLast()
            isDir = true
        }
        return Self.defaultAdvice
    }

    /// The hard refusals for Move to Trash, independent of tier: the roots
    /// and the containers that hold everything, and places already in a Trash.
    public func isRefusedForTrash(canonicalPath path: String, scanRoot: String) -> Bool {
        let trimmed = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        if trimmed == "/" || trimmed == scanRoot || trimmed == home { return true }
        let fixed: Set<String> = [
            home + "/Library", home + "/Desktop", home + "/Documents", home + "/Downloads",
            "/Applications", "/Library", "/System", "/usr", "/usr/local", "/bin", "/sbin",
            "/private", "/private/var", "/private/etc", "/private/tmp", "/opt", "/Users",
            "/Volumes", "/System/Volumes/Data", "/cores", "/etc", "/tmp", "/var", "/dev",
        ]
        if fixed.contains(trimmed) { return true }
        if trimmed.hasPrefix("/System/")
            || trimmed.hasPrefix("/usr/") && !trimmed.hasPrefix("/usr/local/")
            || trimmed.hasPrefix("/bin/") || trimmed.hasPrefix("/sbin/")
            || trimmed.hasPrefix("/private/var/db/") || trimmed.hasPrefix("/private/var/vm")
        {
            return true
        }
        if trimmed.contains("/.Trash/") || trimmed.contains("/.Trashes/")
            || trimmed.hasSuffix("/.Trash")
            || trimmed.hasSuffix("/.Trashes")
        {
            return true
        }
        if let bundle = Self.ownBundlePath, trimmed == bundle || trimmed.hasPrefix(bundle + "/") {
            return true
        }
        return false
    }

    /// The running app's bundle, never trashed from inside itself.
    static var ownBundlePath: String? {
        let path = Bundle.main.bundlePath
        return path.hasSuffix(".app") ? path : nil
    }

    // MARK: - Whole-tree analysis

    /// One forward pass (parents precede children): each node's rule is its
    /// own match or its parent's, tiers follow, Reclaim items are the nodes
    /// where a rule first applies, and kinds are totalled over leaves with
    /// packages rolled up.
    public func analyze(
        _ snapshot: DiskMapSnapshot, firmlinks: FirmlinkMap = .system
    ) -> DiskMapAnalysis {
        let tree = snapshot.tree
        let n = tree.nodeCount
        var tiers = [UInt8](
            repeating: UInt8(DiskMapSafetyTier.reviewBeforeRemoving.rawValue), count: n)
        var ruleIndex = [Int16](repeating: -1, count: n)
        var reclaim: [DiskMapReclaimItem] = []
        var kindBytes = [UInt64](repeating: 0, count: FileKind.allCases.count)
        var kindCount = [UInt64](repeating: 0, count: FileKind.allCases.count)
        var kindItems = [[(bytes: UInt64, node: Int32)]](
            repeating: [], count: FileKind.allCases.count)
        var trashedBytes: UInt64 = 0
        guard n > 0 else {
            return DiskMapAnalysis(
                revision: snapshot.revision, tiers: [], ruleIndex: [], reclaim: [], kinds: [],
                trashedBytes: 0)
        }

        // Canonical path per directory, built from the parent's so no walk up
        // the tree is ever repeated. Files never need theirs.
        var directoryPath = [String?](repeating: nil, count: n)
        let rootPath = firmlinks.canonicalPath(snapshot.rootPath)
        directoryPath[0] = rootPath
        // Package roll-up: the kind a node's bytes count towards, when an
        // ancestor (or the node) is a package.
        var packageKind = [UInt8](repeating: UInt8.max, count: n)
        if tree.flags[0].contains(.package) { packageKind[0] = tree.kind[0].rawValue }

        for i in 1..<n {
            let p = Int(tree.parent[i])
            let flags = tree.flags[i]
            let isDirectory = flags.contains(.directory)
            let isFold = flags.contains(.smallFilesFold)

            // Paths and rules.
            var own: Int? = nil
            if isDirectory && !isFold {
                let parentPath = directoryPath[p] ?? rootPath
                let name = tree.name(of: Int32(i))
                let full = firmlinks.canonicalPath(
                    parentPath == "/" ? "/" + name : parentPath + "/" + name)
                directoryPath[i] = full
                own = matchDirectory(path: full, name: name)
            } else if !isFold {
                let name = tree.name(of: Int32(i))
                own = matchFile(name: name, parentPath: directoryPath[p] ?? rootPath)
            }
            let inherited = ruleIndex[p]
            let effective: Int16 = own.map { Int16($0) } ?? inherited
            ruleIndex[i] = effective
            var tier: DiskMapSafetyTier
            if let override = flagAdvice(flags) {
                tier = override.tier
            } else if effective >= 0 {
                tier = rules[Int(effective)].tier
            } else {
                tier = .reviewBeforeRemoving
            }
            tiers[i] = UInt8(tier.rawValue)
            if let own, Int16(own) != inherited, tree.bytes[i] > 0, !flags.contains(.trashed) {
                reclaim.append(
                    DiskMapReclaimItem(
                        node: Int32(i), bytes: tree.bytes[i], count: tree.count[i],
                        advice: advice(for: rules[own])))
            }
            // Kinds.
            if flags.contains(.trashed) {
                if !isDirectory || packageKind[p] == UInt8.max { trashedBytes &+= tree.bytes[i] }
                packageKind[i] = packageKind[p]
                continue
            }
            let inheritedKind = packageKind[p]
            if inheritedKind != UInt8.max {
                // Inside a package: the package node already counted this
                // subtree, so only the kind is inherited.
                packageKind[i] = inheritedKind
                continue
            }
            if flags.contains(.package) {
                let kind = tree.kind[i]
                packageKind[i] = kind.rawValue
                kindBytes[Int(kind.rawValue)] &+= tree.bytes[i]
                kindCount[Int(kind.rawValue)] &+= 1
                if tree.bytes[i] > 0 {
                    kindItems[Int(kind.rawValue)].append((tree.bytes[i], Int32(i)))
                }
                continue
            }
            if !isDirectory || isFold {
                let kind = tree.kind[i]
                kindBytes[Int(kind.rawValue)] &+= tree.bytes[i]
                kindCount[Int(kind.rawValue)] &+= UInt64(isFold ? tree.count[i] : 1)
                if !isFold, tree.bytes[i] > 0 {
                    kindItems[Int(kind.rawValue)].append((tree.bytes[i], Int32(i)))
                }
            }
        }

        reclaim.sort { $0.bytes > $1.bytes }
        var kinds: [DiskMapKindTotal] = []
        for kind in FileKind.displayOrder where kindBytes[Int(kind.rawValue)] > 0 {
            var items = kindItems[Int(kind.rawValue)]
            items.sort { $0.bytes > $1.bytes }
            kinds.append(
                DiskMapKindTotal(
                    kind: kind, bytes: kindBytes[Int(kind.rawValue)],
                    count: kindCount[Int(kind.rawValue)],
                    topItems: items.prefix(Self.topItemsPerKind).map(\.node)))
        }
        kinds.sort { $0.bytes > $1.bytes }
        return DiskMapAnalysis(
            revision: snapshot.revision, tiers: tiers, ruleIndex: ruleIndex, reclaim: reclaim,
            kinds: kinds, trashedBytes: trashedBytes)
    }

    public static let topItemsPerKind = 200

    /// The advice for a node given a finished analysis.
    public func advice(
        for node: Int32, in analysis: DiskMapAnalysis, tree: FileTree
    ) -> DiskMapAdvice {
        let flags = tree.flags[Int(node)]
        if let override = flagAdvice(flags) { return override }
        let index = analysis.ruleIndex[Int(node)]
        guard index >= 0, Int(index) < rules.count else { return Self.defaultAdvice }
        return advice(for: rules[Int(index)])
    }

    // MARK: - Matching

    private func matchDirectory(path: String, name: String) -> Int? {
        if let exact = exactPaths[path] { return exact }
        if let named = anyDepthNames[name] {
            for index in named where !rules[index].isFile { return index }
        }
        if let ext = Self.extension(of: name), let byExt = anyDepthExtensions[ext] {
            for index in byExt where !rules[index].isFile { return index }
        }
        if !wildcard.isEmpty {
            let components = path.split(separator: "/").map(String.init)
            for entry in wildcard where !rules[entry.rule].isFile {
                if Self.matches(components, pattern: entry.components) { return entry.rule }
            }
        }
        return nil
    }

    private func matchFile(name: String, parentPath: String) -> Int? {
        if let named = anyDepthNames[name] {
            for index in named where rules[index].isFile { return index }
        }
        if let ext = Self.extension(of: name), let byExt = anyDepthExtensions[ext] {
            for index in byExt where rules[index].isFile { return index }
        }
        if let exact = exactPaths[parentPath == "/" ? "/" + name : parentPath + "/" + name],
            rules[exact].isFile
        {
            return exact
        }
        if !wildcard.isEmpty {
            var components = parentPath.split(separator: "/").map(String.init)
            components.append(name)
            for entry in wildcard where rules[entry.rule].isFile {
                if Self.matches(components, pattern: entry.components) { return entry.rule }
            }
        }
        return nil
    }

    private func match(components: [String], isDirectory: Bool) -> Int? {
        guard let name = components.last else { return nil }
        let path = "/" + components.joined(separator: "/")
        if isDirectory {
            return matchDirectory(path: path, name: name)
        }
        let parent = "/" + components.dropLast().joined(separator: "/")
        return matchFile(name: name, parentPath: parent)
    }

    private static func matches(_ components: [String], pattern: [String]) -> Bool {
        guard components.count == pattern.count else { return false }
        for (component, token) in zip(components, pattern) {
            if token == "*" { continue }
            if token.hasPrefix("*.") {
                guard let ext = Self.extension(of: component),
                    ext == token.dropFirst(2).lowercased()
                else { return false }
                continue
            }
            if token != component { return false }
        }
        return true
    }

    private static func `extension`(of name: String) -> String? {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex,
            name.index(after: dot) < name.endIndex
        else { return nil }
        return name[name.index(after: dot)...].lowercased()
    }

    private func flagAdvice(_ flags: FileNodeFlags) -> DiskMapAdvice? {
        if flags.contains(.restricted) || flags.contains(.immutable) {
            return DiskMapAdvice(
                tier: .systemProtected, title: "Protected by macOS",
                reason:
                    "System Integrity Protection locks this item; macOS will not let it be removed.",
                howToReclaim: nil)
        }
        if flags.contains(.separateVolume) {
            return DiskMapAdvice(
                tier: .systemProtected, title: "Another volume",
                reason:
                    "A volume is mounted here; its contents belong to that volume, not this one.",
                howToReclaim: "Scan the volume itself from the scope menu.")
        }
        if flags.contains(.dataless) {
            return DiskMapAdvice(
                tier: .managedByApp, title: "Stored in iCloud",
                reason: "This item lives in the cloud and takes no local space until downloaded.",
                howToReclaim: nil)
        }
        if flags.contains(.dataVault) {
            return DiskMapAdvice(
                tier: .systemProtected, title: "Data vault",
                reason: "Only Apple's own software may read or change this folder.",
                howToReclaim: nil)
        }
        return nil
    }

    private func advice(for rule: Rule) -> DiskMapAdvice {
        DiskMapAdvice(
            tier: rule.tier, title: rule.title, reason: rule.reason, howToReclaim: rule.howToReclaim
        )
    }

    static let defaultAdvice = DiskMapAdvice(
        tier: .reviewBeforeRemoving, title: "Your files",
        reason:
            "Nothing here is known to be a cache or to belong to macOS, so check what it is before removing it.",
        howToReclaim: "Move it to the Trash, then empty the Trash in Finder to free the space.")

    // MARK: - The rules

    private static func rule(
        _ pattern: String, _ tier: DiskMapSafetyTier, _ title: String, _ reason: String,
        how: String? = nil, file: Bool = false
    ) -> Rule {
        Rule(
            pattern: pattern, tier: tier, title: title, reason: reason, howToReclaim: how,
            isFile: file)
    }

    public static let defaultRules: [Rule] = [
        // Protected.
        rule(
            "/System", .systemProtected, "macOS", "The operating system itself.",
            how: nil),
        rule("/usr", .systemProtected, "macOS", "Unix tools and libraries the system depends on."),
        rule("/bin", .systemProtected, "macOS", "Core Unix tools."),
        rule("/sbin", .systemProtected, "macOS", "Core Unix tools."),
        rule(
            "/Library/Apple", .systemProtected, "macOS", "Apple software installed with the system."
        ),
        rule(
            "/private/var/vm", .systemProtected, "Virtual memory",
            "Swap and sleep images; macOS grows and shrinks them itself.",
            how: "Quitting memory-hungry apps lets macOS release swap."),
        rule(
            "/private/var/folders", .systemProtected, "System caches",
            "Per-user caches and temporary files that macOS manages and clears on restart.",
            how: "Restart the Mac to let macOS clear what it no longer needs."),
        rule(
            "/private/var/db", .systemProtected, "System databases",
            "Databases macOS keeps for Spotlight, the unified log, updates and more."),
        rule(
            "/private/var/db/diagnostics", .systemProtected, "Unified log",
            "The system log store; macOS trims it on its own schedule."),
        rule(
            "/private/var/db/uuidtext", .systemProtected, "Unified log",
            "Symbol data for the system log; macOS trims it on its own schedule."),
        rule(
            "/System/Library/AssetsV2", .systemProtected, "System assets",
            "Downloaded system content such as simulator runtimes and dictionaries.",
            how: "Simulator runtimes: xcrun simctl runtime delete <id>."),
        rule(
            "/Library/Developer/CoreSimulator/Volumes", .systemProtected, "Simulator runtimes",
            "Mounted simulator runtime images; their space is in the images, not here."),
        rule("/Library/Updates", .systemProtected, "macOS updates", "Staged system updates."),
        // Managed by an app.
        rule(
            "**/*.photoslibrary", .managedByApp, "Photos library",
            "Photos keeps its database and originals in here; changing it by hand corrupts the library.",
            how:
                "Delete photos in Photos, then empty its Recently Deleted album, or turn on Optimise Mac Storage."
        ),
        rule(
            "~/Library/Mail", .managedByApp, "Mail",
            "Mail's downloaded messages and attachments.",
            how:
                "In Mail, remove attachments or set Settings > Accounts > Download Attachments to None."
        ),
        rule(
            "~/Library/Messages", .managedByApp, "Messages",
            "Messages history and attachments.",
            how:
                "Messages > Settings > General > Keep Messages, or delete large conversations in Messages."
        ),
        rule(
            "~/Library/Application Support/MobileSync/Backup", .managedByApp,
            "iPhone and iPad backups",
            "Local device backups made by Finder.",
            how: "Finder > the device > Manage Backups to delete old ones safely."),
        rule(
            "~/Library/Containers/com.docker.docker/Data/vms/*/data/Docker.raw", .managedByApp,
            "Docker disk image",
            "Docker's virtual disk. It is sparse, so its true size is what the map shows.",
            how: "docker system prune, or Docker Desktop > Settings > Resources to shrink it.",
            file: true),
        rule(
            "~/Library/Developer/CoreSimulator/Devices", .managedByApp, "Simulator devices",
            "Data of every iOS, watchOS and tvOS simulator created by Xcode.",
            how: "xcrun simctl delete unavailable, or Xcode > Window > Devices and Simulators."),
        rule(
            "/Library/Developer/CoreSimulator/Images", .managedByApp, "Simulator runtime images",
            "Simulator runtimes downloaded by Xcode.",
            how: "xcrun simctl runtime delete <id>, or Xcode > Settings > Components."),
        rule(
            "/Library/Developer/CoreSimulator/Caches", .managedByApp, "Simulator caches",
            "Shared caches built for each simulator runtime.",
            how: "Deleting the runtime removes its cache."),
        rule(
            "~/Library/CloudStorage", .managedByApp, "Cloud storage",
            "Files synced by a cloud provider; removing them here removes them everywhere.",
            how:
                "In Finder, choose Remove Download to keep the file in the cloud but free the local copy."
        ),
        rule(
            "~/Library/Mobile Documents", .managedByApp, "iCloud Drive",
            "iCloud Drive files; removing them here removes them from every device.",
            how:
                "In Finder, choose Remove Download to keep the file in iCloud but free the local copy."
        ),
        rule(
            "/opt/homebrew/Cellar", .managedByApp, "Homebrew packages",
            "Installed Homebrew formulae.",
            how: "brew uninstall <formula>, brew autoremove, brew cleanup."),
        rule(
            "/usr/local/Cellar", .managedByApp, "Homebrew packages",
            "Installed Homebrew formulae.",
            how: "brew uninstall <formula>, brew autoremove, brew cleanup."),
        rule(
            "**/*.vmwarevm", .managedByApp, "Virtual machine", "A VMware virtual machine.",
            how: "Delete it from VMware Fusion."),
        rule(
            "**/*.pvm", .managedByApp, "Virtual machine", "A Parallels virtual machine.",
            how: "Delete it from Parallels Desktop."),
        rule(
            "**/*.utm", .managedByApp, "Virtual machine", "A UTM virtual machine.",
            how: "Delete it from UTM."),
        rule(
            "**/*.vbvm", .managedByApp, "Virtual machine", "A VirtualBuddy virtual machine.",
            how: "Delete it from VirtualBuddy."),
        rule(
            "~/Library/Application Support/Steam/steamapps", .managedByApp, "Steam games",
            "Installed games.", how: "Uninstall from Steam."),
        rule(
            "~/Music/Music/Media.localized", .managedByApp, "Music library",
            "Your music library's media.", how: "Remove downloads in Music."),
        rule(
            "~/Movies/TV", .managedByApp, "TV downloads", "Downloaded TV app content.",
            how: "Remove downloads in the TV app."),
        rule(
            "~/Library/Group Containers", .managedByApp, "App data",
            "Data shared between an app and its extensions.",
            how: "Manage storage inside the app, or remove the app."),
        // Safe to remove.
        rule(
            "~/Library/Caches", .safeToRemove, "User caches",
            "Caches apps rebuild when they need them.",
            how: "Quit the apps first; they recreate what they need."),
        rule(
            "/Library/Caches", .safeToRemove, "System caches",
            "Caches shared by all users; rebuilt on demand."),
        rule(
            "~/Library/Developer/Xcode/DerivedData", .safeToRemove, "Xcode DerivedData",
            "Build products and indexes; Xcode rebuilds them on the next build.",
            how: "Xcode > Settings > Locations > Derived Data, or trash it while Xcode is closed."),
        rule(
            "~/Library/Developer/Xcode/iOS DeviceSupport", .safeToRemove, "iOS device support",
            "Symbols for every iOS version you have debugged; re-downloaded when a device connects.",
            how: "Keep the folders for OS versions you still debug on."),
        rule(
            "~/Library/Developer/Xcode/watchOS DeviceSupport", .safeToRemove,
            "watchOS device support",
            "Symbols for every watchOS version you have debugged."),
        rule(
            "~/Library/Developer/Xcode/tvOS DeviceSupport", .safeToRemove, "tvOS device support",
            "Symbols for every tvOS version you have debugged."),
        rule(
            "~/Library/Developer/Xcode/iOS Device Logs", .safeToRemove, "Device logs",
            "Crash and console logs copied from devices."),
        rule(
            "~/Library/Developer/CoreSimulator/Caches", .safeToRemove, "Simulator caches",
            "Caches the simulators rebuild."),
        rule(
            "~/Library/Developer/Xcode/Archives", .reviewBeforeRemoving, "Xcode archives",
            "App archives with the dSYMs needed to symbolicate crash reports for shipped builds.",
            how: "Keep archives of versions still in use; delete the rest in the Organizer."),
        rule(
            "~/Library/Logs", .safeToRemove, "Logs",
            "Diagnostic logs; new ones are written as needed."),
        rule("/Library/Logs", .safeToRemove, "System logs", "Shared diagnostic logs."),
        rule(
            "~/Library/Caches/Homebrew", .safeToRemove, "Homebrew downloads",
            "Downloaded bottles and sources.", how: "brew cleanup --prune=all."),
        rule(
            "~/Library/Caches/pip", .safeToRemove, "pip cache", "Downloaded Python packages.",
            how: "pip cache purge."),
        rule(
            "~/.npm", .safeToRemove, "npm cache", "Downloaded Node packages.",
            how: "npm cache clean --force."),
        rule("~/.cache", .safeToRemove, "Tool caches", "Caches kept by command-line tools."),
        rule(
            "~/.cargo/registry", .safeToRemove, "Cargo registry", "Downloaded Rust crates.",
            how: "cargo cache -a (cargo-cache), or trash it; cargo re-downloads."),
        rule(
            "~/.gradle/caches", .safeToRemove, "Gradle caches",
            "Downloaded dependencies and build caches."),
        rule(
            "~/Library/pnpm", .safeToRemove, "pnpm store", "Downloaded Node packages.",
            how: "pnpm store prune."),
        rule(
            "~/.pnpm-store", .safeToRemove, "pnpm store", "Downloaded Node packages.",
            how: "pnpm store prune."),
        rule(
            "~/.yarn/berry/cache", .safeToRemove, "Yarn cache", "Downloaded Node packages.",
            how: "yarn cache clean."),
        rule(
            "~/Library/Caches/CocoaPods", .safeToRemove, "CocoaPods cache", "Downloaded pods.",
            how: "pod cache clean --all."),
        rule(
            "~/.cocoapods/repos", .safeToRemove, "CocoaPods specs",
            "Podspec repositories; re-cloned on demand."),
        rule(
            "**/node_modules", .safeToRemove, "Dependencies (node_modules)",
            "Installed Node packages for a project; the package manager recreates them.",
            how: "npm install (or yarn, pnpm) in the project restores them."),
        rule(
            "**/DerivedData", .safeToRemove, "DerivedData",
            "Xcode build products; rebuilt on the next build."),
        rule(
            "~/.Trash", .safeToRemove, "Trash",
            "Items you already removed; the space is not free until the Trash is emptied.",
            how: "Empty the Trash in Finder."),
        // Review.
        rule(
            "~/Downloads", .reviewBeforeRemoving, "Downloads",
            "Installers, archives and files you downloaded, often no longer needed.",
            how: "Trash what you have already installed or copied elsewhere."),
        rule("~/Desktop", .reviewBeforeRemoving, "Desktop", "Files kept on the Desktop."),
        rule("~/Documents", .reviewBeforeRemoving, "Documents", "Your documents."),
        rule(
            "~/Movies", .reviewBeforeRemoving, "Movies",
            "Your videos, usually the largest files you own."),
        rule(
            "~/Pictures", .reviewBeforeRemoving, "Pictures",
            "Your photos and images outside Photos."),
        rule("~/Music", .reviewBeforeRemoving, "Music", "Your music files."),
        rule(
            "/Applications", .reviewBeforeRemoving, "Applications",
            "Installed apps.", how: "Drag an app to the Trash, or use its uninstaller."),
        rule(
            "**/*.dmg", .reviewBeforeRemoving, "Disk image",
            "An installer or disk image, usually disposable once its contents are installed.",
            file: true),
        rule(
            "**/*.iso", .reviewBeforeRemoving, "Disc image", "A disc image, often an OS installer.",
            file: true),
        rule(
            "**/*.ipsw", .reviewBeforeRemoving, "iOS restore image",
            "A firmware image used to restore a device; re-downloadable.", file: true),
    ]
}
