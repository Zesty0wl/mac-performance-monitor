import Foundation

/// One launchd job definition: a property list that tells launchd to run a
/// program.
public struct LaunchJob: Sendable, Equatable {
    /// Where the job file lives, which decides who it runs as and when.
    public enum Domain: String, Sendable {
        /// `/System/Library/LaunchDaemons` or `/Library/LaunchDaemons`: runs
        /// as a system service, with or without anyone logged in.
        case daemon
        /// `/System/Library/LaunchAgents` or `/Library/LaunchAgents`: runs in
        /// every user's login session.
        case agent
        /// `~/Library/LaunchAgents`: runs in this user's login session only.
        case userAgent
        /// Inside an app, under `Contents/Library/LaunchDaemons`: a system
        /// service the app registered (`SMAppService`).
        case appDaemon
        /// Inside an app, under `Contents/Library/LaunchAgents`.
        case appAgent
    }

    public var plistPath: String
    public var label: String?
    /// The program the job runs, as an absolute path with symlinks resolved.
    public var program: String
    public var domain: Domain

    public init(plistPath: String, label: String?, program: String, domain: Domain) {
        self.plistPath = plistPath
        self.label = label
        self.program = program
        self.domain = domain
    }
}

/// How a process came to be running, as far as files on disk can tell.
public enum LaunchOrigin: Sendable, Equatable {
    /// launchd started it for this job.
    case job(LaunchJob)
    /// launchd started it on demand as an XPC service of the bundle at `owner`.
    case xpcService(owner: String)
    /// Another process started it.
    case parent(pid: Int32, name: String)
    /// launchd is its parent and no job file names it. That is the normal
    /// state of an app opened from the Dock or Finder.
    case unknown
}

/// The launchd jobs found in a set of folders, looked up by the program they run.
public struct LaunchJobIndex: Sendable {
    private var byProgram: [String: LaunchJob] = [:]

    public var count: Int { byProgram.count }

    public init(jobs: [LaunchJob] = []) {
        // The first job naming a program wins; folders are scanned most
        // specific first by `standardDirectories`.
        for job in jobs where byProgram[job.program] == nil { byProgram[job.program] = job }
    }

    /// The job that runs the executable at `path`, matched on the exact file.
    /// A matching file name elsewhere is deliberately not enough: two
    /// different programs called "agent" are common.
    public func job(forExecutable path: String) -> LaunchJob? {
        byProgram[Self.normalized(path)]
    }

    /// The system-wide and per-user job folders, with the domain each implies.
    public static func standardDirectories(
        home: String = NSHomeDirectory()
    )
        -> [(path: String, domain: LaunchJob.Domain)]
    {
        [
            ((home as NSString).appendingPathComponent("Library/LaunchAgents"), .userAgent),
            ("/Library/LaunchDaemons", .daemon),
            ("/Library/LaunchAgents", .agent),
            ("/System/Library/LaunchDaemons", .daemon),
            ("/System/Library/LaunchAgents", .agent),
        ]
    }

    /// Read every job file in `directories`. Unreadable folders and malformed
    /// files are skipped.
    public static func scan(
        directories: [(path: String, domain: LaunchJob.Domain)]
    )
        -> LaunchJobIndex
    {
        var jobs: [LaunchJob] = []
        for directory in directories {
            jobs += Self.jobs(inDirectory: directory.path, domain: directory.domain, bundle: nil)
        }
        return LaunchJobIndex(jobs: jobs)
    }

    /// The jobs an app carries inside its own bundle, which is where
    /// `SMAppService` daemons and agents live. `bundle` is the path of the
    /// `.app`.
    public static func jobs(inBundle bundle: String) -> [LaunchJob] {
        let library = (bundle as NSString).appendingPathComponent("Contents/Library")
        return jobs(
            inDirectory: (library as NSString).appendingPathComponent("LaunchDaemons"),
            domain: .appDaemon, bundle: bundle)
            + jobs(
                inDirectory: (library as NSString).appendingPathComponent("LaunchAgents"),
                domain: .appAgent, bundle: bundle)
    }

    private static func jobs(
        inDirectory directory: String, domain: LaunchJob.Domain, bundle: String?
    )
        -> [LaunchJob]
    {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
            return []
        }
        return names.sorted().compactMap { name -> LaunchJob? in
            guard name.hasSuffix(".plist") else { return nil }
            let path = (directory as NSString).appendingPathComponent(name)
            guard let data = FileManager.default.contents(atPath: path),
                let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
                    as? [String: Any],
                let program = program(in: plist, bundle: bundle)
            else { return nil }
            return LaunchJob(
                plistPath: path, label: plist["Label"] as? String, program: normalized(program),
                domain: domain)
        }
    }

    /// The program a job runs: `Program`, else the first of
    /// `ProgramArguments`, else `BundleProgram` relative to the app.
    private static func program(in plist: [String: Any], bundle: String?) -> String? {
        if let program = plist["Program"] as? String, program.hasPrefix("/") { return program }
        if let first = (plist["ProgramArguments"] as? [String])?.first, first.hasPrefix("/") {
            return first
        }
        if let bundle, let relative = plist["BundleProgram"] as? String, !relative.isEmpty {
            return (bundle as NSString).appendingPathComponent(relative)
        }
        return nil
    }

    /// One spelling per file: symlinks resolved, and the cryptex prefixes
    /// macOS adds to the real location of some system apps removed, so a
    /// running process's path and a job file's path compare equal.
    static func normalized(_ path: String) -> String {
        var path = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        for prefix in [
            "/System/Volumes/Preboot/Cryptexes/App", "/System/Volumes/Preboot/Cryptexes/OS",
            "/System/Cryptexes/App", "/System/Cryptexes/OS",
        ] where path.hasPrefix(prefix + "/") {
            path.removeFirst(prefix.count)
            break
        }
        return path
    }

    /// The outermost `.app` containing `path`, if any.
    public static func enclosingApp(of path: String) -> String? {
        guard let range = path.range(of: ".app/") else { return nil }
        return String(path[..<range.lowerBound]) + ".app"
    }

    /// The bundle that owns an XPC service executable
    /// (`…/Owner.app/Contents/XPCServices/Name.xpc/Contents/MacOS/Name`), or
    /// the `.xpc` bundle itself when it stands alone.
    static func xpcOwner(of path: String) -> String? {
        guard let xpc = path.range(of: ".xpc/Contents/MacOS/") else { return nil }
        let service = String(path[..<xpc.lowerBound]) + ".xpc"
        for marker in ["/Contents/XPCServices/", "/Versions/A/XPCServices/", "/XPCServices/"] {
            if let owner = service.range(of: marker, options: .backwards) {
                return String(service[..<owner.lowerBound])
            }
        }
        return service
    }
}

extension LaunchOrigin {
    /// Work out how the process at `executablePath` was started.
    ///
    /// A job file naming the executable is the strongest evidence, wherever
    /// the parent is. Failing that, an XPC service is recognised by where it
    /// sits, then a parent other than launchd is taken at its word.
    public static func resolve(
        executablePath: String?, parentPID: Int32, parentName: String?, index: LaunchJobIndex,
        bundledJobs: (String) -> [LaunchJob] = LaunchJobIndex.jobs(inBundle:)
    ) -> LaunchOrigin {
        if let path = executablePath, !path.isEmpty {
            if let job = index.job(forExecutable: path) { return .job(job) }
            if let app = LaunchJobIndex.enclosingApp(of: path) {
                let wanted = LaunchJobIndex.normalized(path)
                if let job = bundledJobs(app).first(where: { $0.program == wanted }) {
                    return .job(job)
                }
            }
            if parentPID <= 1, let owner = LaunchJobIndex.xpcOwner(of: path) {
                return .xpcService(owner: owner)
            }
        }
        if parentPID > 1 {
            return .parent(pid: parentPID, name: parentName ?? "PID \(parentPID)")
        }
        return .unknown
    }
}

/// The standard job folders, scanned once and kept. Scanning reads several
/// hundred small files, so it happens off the main thread on first use and is
/// refreshed only when the copy is old.
public actor LaunchJobIndexCache {
    public static let shared = LaunchJobIndexCache()

    private var index: LaunchJobIndex?
    private var scannedAt: Date?
    private let lifetime: TimeInterval = 5 * 60

    public func current(now: Date = Date()) -> LaunchJobIndex {
        if let index, let scannedAt, now.timeIntervalSince(scannedAt) < lifetime { return index }
        let fresh = LaunchJobIndex.scan(directories: LaunchJobIndex.standardDirectories())
        index = fresh
        scannedAt = now
        return fresh
    }
}
