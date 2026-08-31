import CryptoKit
import Foundation
import GRDB
import MacPerfMonitorCore

// macperfmonitor-cli: Milestone 0 data-layer spike.
//
// Run as a normal user, this harness records, for every visible process, which
// libproc reads succeed or fail, classifies the failures by ownership, samples
// system-wide VM/swap/pressure, and prints a report used to author
// docs/data-layer-findings.md and decide how much per-process coverage direct
// user-level reads provide.

/// Set false by SIGINT so the `sample` loop can stop and print a summary.
var keepRunning = true
func onInterrupt(_ signal: Int32) { keepRunning = false }

let arguments = CommandLine.arguments
let command = arguments.count > 1 ? arguments[1] : "probe"

switch command {
case "probe":
    runProbe()
case "sample":
    runSample(arguments: Array(arguments.dropFirst(2)))
case "scan":
    runScan(arguments: Array(arguments.dropFirst(2)))
case "emit-checks":
    // Emit the built-in diagnostic check catalog as JSON, so the publish script can
    // seed the server manifest from the in-app pack without drift.
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(CheckCatalog.builtIn),
        let json = String(data: data, encoding: .utf8)
    else {
        FileHandle.standardError.write(Data("failed to encode catalog\n".utf8))
        exit(1)
    }
    print(json)
case "verify-checks":
    // verify-checks <manifest.json> <signature.b64> <pubkey.b64> — verify a catalog
    // signature exactly as the client does (CryptoKit Ed25519), so the publish path
    // can guarantee clients will accept what it ships.
    let a = Array(arguments.dropFirst(2))
    guard a.count == 3,
        let manifestData = try? Data(contentsOf: URL(fileURLWithPath: a[0])),
        let sigB64 = try? String(contentsOfFile: a[1], encoding: .utf8).trimmingCharacters(
            in: .whitespacesAndNewlines),
        let sig = Data(base64Encoded: sigB64),
        let keyData = Data(base64Encoded: a[2]),
        let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData)
    else {
        FileHandle.standardError.write(
            Data("usage: verify-checks <manifest.json> <signature.b64> <pubkey.b64>\n".utf8))
        exit(2)
    }
    if key.isValidSignature(sig, for: manifestData) {
        print("OK: signature valid (CryptoKit Ed25519) — clients will accept it.")
    } else {
        FileHandle.standardError.write(Data("FAIL: signature invalid\n".utf8))
        exit(1)
    }
case "help", "-h", "--help":
    printUsage()
default:
    FileHandle.standardError.write(Data("Unknown command: \(command)\n\n".utf8))
    printUsage()
    exit(2)
}

func printUsage() {
    print(
        """
        macperfmonitor-cli — MacPerfMonitor headless diagnostics

        Usage:
          macperfmonitor-cli probe                      Probe per-process read coverage and system memory (default)
          macperfmonitor-cli sample [options]           Continuously sample into the database
          macperfmonitor-cli scan [path] [options]      Scan a folder or volume with the Disk Map engine
          macperfmonitor-cli help                       Show this help

        scan options (path defaults to the home folder; / means the startup disk):
          --workers <n>          Reader threads (default \(DiskMapScanOptions.defaultWorkerCount))
          --threshold <bytes>    Small-file fold threshold (default: adaptive from inode count)
          --no-fold              Keep every file as its own node
          --private-size         Fetch ATTR_CMNEXT_PRIVATESIZE per entry (about 1.5x slower)
          --no-throttle          Do not mark reads as utility-class IO
          --top <n>              Largest directories and files to list (default 15)
          --json                 Print the summary as JSON instead of text
          --quiet                No progress line

        sample options:
          --interval <seconds>   Sampling cadence (default 2.0)
          --duration <seconds>   How long to run, 0 = until interrupted (default 20)
          --db <path>            Database path (default: a temp file)
        """)
}

func runProbe() {
    let myUID = getuid()
    let processReader = ProcessReader()
    let memoryReader = SystemMemoryReader()

    printSection("Host & system memory")
    let pageSize = memoryReader.pageSize
    let totalRAM = memoryReader.totalRAM
    print("  Total RAM:       \(ByteFormat.string(totalRAM))")
    print("  Page size:       \(pageSize) bytes")
    print(
        "  Host arch:       \(ProcessReader.hostIsAppleSilicon ? "Apple Silicon (arm64)" : "Intel (x86_64)")"
    )
    print("  Pressure level:  \(memoryReader.pressureLevel().label)")

    if let vm = memoryReader.sampleVM() {
        print("  VM wired:        \(ByteFormat.string(vm.wired))")
        print("  VM active:       \(ByteFormat.string(vm.active))")
        print("  VM inactive:     \(ByteFormat.string(vm.inactive))")
        print("  VM speculative:  \(ByteFormat.string(vm.speculative))")
        print("  VM compressed:   \(ByteFormat.string(vm.compressed))")
        print("  VM free:         \(ByteFormat.string(vm.free))")
        print("  VM file-backed:  \(ByteFormat.string(vm.external))")
        print("  VM anonymous:    \(ByteFormat.string(vm.internal))")
        print("  pageins/outs:    \(vm.pageIns) / \(vm.pageOuts)")
        print("  compress/decmp:  \(vm.compressions) / \(vm.decompressions)")
    } else {
        print("  VM statistics:   UNAVAILABLE (host_statistics64 failed)")
    }
    if let swap = memoryReader.sampleSwap() {
        print(
            "  Swap used/total: \(ByteFormat.string(swap.used)) / \(ByteFormat.string(swap.total))")
    } else {
        print("  Swap:            UNAVAILABLE")
    }

    // Per-process probe.
    let pids = processReader.listPIDs()

    var taskInfoOK = 0, taskInfoFail = 0
    var footprintOK = 0, footprintFail = 0
    var fdOK = 0, fdFail = 0
    var translationOK = 0, translationFail = 0
    var pathOK = 0, pathFail = 0

    // Footprint failures classified by ownership.
    var footprintFailOwned = 0
    var footprintFailRoot = 0
    var footprintFailOther = 0
    var ownedTotal = 0

    struct Row {
        var pid: pid_t
        var name: String
        var footprint: UInt64
        var translated: Bool
        var arch: Architecture
        var fdTotal: Int32
        var uid: uid_t
    }
    var rows: [Row] = []
    rows.reserveCapacity(pids.count)

    var translatedCount = 0
    var translatedFootprint: UInt64 = 0

    for pid in pids {
        let info = processReader.taskAllInfo(pid)
        if let info {
            taskInfoOK += 1
            _ = info
        } else {
            taskInfoFail += 1
        }

        let owned = (info?.uid == myUID)
        if owned { ownedTotal += 1 }

        let rusage = processReader.rusage(pid)
        if let rusage {
            footprintOK += 1
            let translated = processReader.isTranslated(pid) ?? false
            if translated {
                translatedCount += 1
                translatedFootprint &+= rusage.physFootprint
            }
            let fd = processReader.fdBreakdown(pid)
            rows.append(
                Row(
                    pid: pid,
                    name: info?.name ?? "pid \(pid)",
                    footprint: rusage.physFootprint,
                    translated: translated,
                    arch: processReader.architecture(translated: translated),
                    fdTotal: fd?.total ?? -1,
                    uid: info?.uid ?? 0
                ))
        } else {
            footprintFail += 1
            if let uid = info?.uid {
                if uid == myUID {
                    footprintFailOwned += 1
                } else if uid == 0 {
                    footprintFailRoot += 1
                } else {
                    footprintFailOther += 1
                }
            } else {
                footprintFailOther += 1
            }
        }

        if processReader.fdBreakdown(pid) != nil { fdOK += 1 } else { fdFail += 1 }
        if processReader.isTranslated(pid) != nil {
            translationOK += 1
        } else {
            translationFail += 1
        }
        if processReader.path(pid) != nil { pathOK += 1 } else { pathFail += 1 }
    }

    let total = pids.count
    printSection("Per-process read coverage (n = \(total) processes)")
    printCoverage(
        "Basic task info (PROC_PIDTASKALLINFO)", ok: taskInfoOK, fail: taskInfoFail, total: total)
    printCoverage(
        "Footprint (proc_pid_rusage v6)", ok: footprintOK, fail: footprintFail, total: total)
    printCoverage("File descriptors (PROC_PIDLISTFDS)", ok: fdOK, fail: fdFail, total: total)
    printCoverage(
        "Rosetta flag (KERN_PROC_PID)", ok: translationOK, fail: translationFail, total: total)
    printCoverage("Executable path (proc_pidpath)", ok: pathOK, fail: pathFail, total: total)

    printSection("Footprint-read failures by ownership")
    print("  Processes owned by me (uid \(myUID)):        \(ownedTotal)")
    print("  Failures on processes I OWN:                 \(footprintFailOwned)")
    print("  Failures on root-owned (uid 0) processes:    \(footprintFailRoot)")
    print("  Failures on other-user processes:            \(footprintFailOther)")

    printSection("Rosetta (translated) processes")
    print("  Translated process count:  \(translatedCount)")
    print("  Aggregate footprint:       \(ByteFormat.string(translatedFootprint))")

    printSection("Top 10 processes by phys_footprint (readable)")
    let top = rows.sorted { $0.footprint > $1.footprint }.prefix(10)
    print(
        "  " + pad("PID", 8) + pad("NAME", 26) + pad("FOOTPRINT", 12) + pad("ARCH", 9)
            + pad("FDS", 6) + "UID")
    for row in top {
        print(
            "  "
                + pad(String(row.pid), 8)
                + pad(String(row.name.prefix(24)), 26)
                + pad(ByteFormat.string(row.footprint), 12)
                + pad(row.arch.label, 9)
                + pad(row.fdTotal >= 0 ? String(row.fdTotal) : "—", 6)
                + String(row.uid))
    }

    let pctReadable = total > 0 ? Double(footprintOK) / Double(total) * 100 : 0
    printSection("Summary")
    print(String(format: "  Footprint readable for %.1f%% of visible processes.", pctReadable))
    print("  Spot-check a value above against Activity Monitor's Memory column.")
    print("")
}

// MARK: - Continuous sampling

func runSample(arguments: [String]) {
    var interval: TimeInterval = 2.0
    var duration: TimeInterval = 20
    var dbURL: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("macperfmonitor-sample-\(UUID().uuidString).sqlite")

    var i = 0
    while i < arguments.count {
        let arg = arguments[i]
        func nextValue() -> String? {
            guard i + 1 < arguments.count else { return nil }
            i += 1
            return arguments[i]
        }
        switch arg {
        case "--interval":
            if let v = nextValue(), let d = Double(v), d > 0 { interval = d }
        case "--duration":
            if let v = nextValue(), let d = Double(v), d >= 0 { duration = d }
        case "--db":
            if let v = nextValue() {
                dbURL = URL(fileURLWithPath: (v as NSString).expandingTildeInPath)
            }
        default:
            FileHandle.standardError.write(Data("Ignoring unknown option: \(arg)\n".utf8))
        }
        i += 1
    }

    let pool: DatabasePool
    let store: SampleStore
    do {
        pool = try MacPerfMonitorDatabase.makePool(url: dbURL)
        store = SampleStore(pool: pool)
    } catch {
        FileHandle.standardError.write(Data("Failed to open database: \(error)\n".utf8))
        exit(1)
    }

    let sampler = Sampler()

    print(
        "Sampling every \(interval)s"
            + (duration > 0 ? " for \(Int(duration))s" : " until interrupted (Ctrl-C)"))
    print("Database: \(dbURL.path)")
    print("")
    print(
        "  " + pad("time", 10) + pad("pressure", 12) + pad("procs", 8)
            + pad("unread", 8) + "top consumer")
    print("  " + String(repeating: "-", count: 70))

    signal(SIGINT, onInterrupt)
    keepRunning = true

    let start = Date()
    var tickCount = 0
    var lastRetention = start

    while keepRunning {
        let now = Date()
        let snapshot = sampler.tick(now: now)
        do {
            try store.insert(snapshot)
        } catch {
            FileHandle.standardError.write(Data("Insert failed: \(error)\n".utf8))
        }
        tickCount += 1

        // Run retention roughly once a minute so the DB stays bounded.
        if now.timeIntervalSince(lastRetention) >= 60 {
            try? Retention.run(pool, now: now)
            lastRetention = now
        }

        let top = snapshot.processes
            .filter { $0.footprintReadable }
            .max { $0.physFootprint < $1.physFootprint }
        let topLabel = top.map { "\($0.name) (\(ByteFormat.string($0.physFootprint)))" } ?? "—"
        let elapsed = Int(now.timeIntervalSince(start))
        let pressure =
            "\(snapshot.system.pressureLevel) "
            + String(format: "%.0f%%", snapshot.system.pressurePercent)
        print(
            "  " + pad("+\(elapsed)s", 10) + pad(pressure, 12)
                + pad("\(snapshot.processes.count)", 8)
                + pad("\(snapshot.unreadableProcessCount)", 8) + topLabel)

        if duration > 0 && now.timeIntervalSince(start) >= duration { break }
        if keepRunning { Thread.sleep(forTimeInterval: interval) }
    }

    // Final retention pass, then report DB size and row counts.
    try? Retention.run(pool, now: Date())

    printSection("Database summary")
    if let stats = try? store.stats() {
        print("  process_samples : \(stats.processSamples)")
        print("  system_samples  : \(stats.systemSamples)")
        print("  process_minute  : \(stats.processMinute)")
        print("  process_hour    : \(stats.processHour)")
        print("  system_minute   : \(stats.systemMinute)")
        print("  system_hour     : \(stats.systemHour)")
        print("  processes       : \(stats.processes)")
    }
    let onDisk = databaseSizeOnDisk(dbURL)
    print("  on-disk size    : \(ByteFormat.string(onDisk)) (incl. WAL/SHM)")
    print("  ticks recorded  : \(tickCount)")
    print("")
}

// MARK: - Disk Map scan

/// Headless run of the Disk Map engine: the harness for measuring throughput,
/// memory and the fold threshold, and for checking totals against `du -sk`.
func runScan(arguments: [String]) {
    var path = NSHomeDirectory()
    var options = DiskMapScanOptions()
    var top = 15
    var json = false
    var quiet = false

    var i = 0
    while i < arguments.count {
        let arg = arguments[i]
        func nextValue() -> String? {
            guard i + 1 < arguments.count else { return nil }
            i += 1
            return arguments[i]
        }
        switch arg {
        case "--workers":
            if let v = nextValue(), let n = Int(v), n > 0 { options.workerCount = n }
        case "--threshold":
            if let v = nextValue(), let n = UInt64(v) { options.smallFileThreshold = n }
        case "--no-fold":
            options.smallFileThreshold = 0
        case "--private-size":
            options.fetchPrivateSize = true
        case "--no-throttle":
            options.throttleIO = false
        case "--top":
            if let v = nextValue(), let n = Int(v), n >= 0 { top = n }
        case "--json":
            json = true
        case "--quiet":
            quiet = true
        default:
            if arg.hasPrefix("--") {
                FileHandle.standardError.write(Data("Ignoring unknown option: \(arg)\n".utf8))
            } else {
                path = (arg as NSString).expandingTildeInPath
            }
        }
        i += 1
    }

    let scope = DiskMapScope.resolved(folder: path)
    let token = DiskMapCancellationToken()
    signal(SIGINT, onInterrupt)
    keepRunning = true

    if !quiet {
        FileHandle.standardError.write(
            Data(
                "Scanning \(scope.scanRoot) (\(scope.rootName)), workers \(options.workerCount)\n"
                    .utf8))
    }
    let started = Date()
    var lastLine = Date.distantPast
    let snapshot: DiskMapSnapshot
    do {
        snapshot = try DiskMapScanner().scanBlocking(scope, options: options, cancellation: token) {
            progress, _ in
            if !keepRunning { token.cancel() }
            guard !quiet, Date().timeIntervalSince(lastLine) >= 1 else { return }
            lastLine = Date()
            let rate = progress.elapsed > 0 ? Double(progress.entries) / progress.elapsed : 0
            let location =
                progress.currentPath.count > 60
                ? "…" + progress.currentPath.suffix(59) : progress.currentPath
            let line = String(
                format: "  %6.1fs  %9llu entries  %7.0f/s  %10@  %@\n", progress.elapsed,
                progress.entries, rate, ByteFormat.string(progress.bytes), location)
            FileHandle.standardError.write(Data(line.utf8))
        }
    } catch {
        FileHandle.standardError.write(Data("Scan failed: \(error.localizedDescription)\n".utf8))
        exit(1)
    }

    let elapsed = Date().timeIntervalSince(started)
    let tree = snapshot.tree
    let rec = snapshot.reconciliation
    let counts = rec.counts
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    let peakRSS = UInt64(max(0, usage.ru_maxrss))
    let openFDs = (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd"))?.count ?? -1
    let rate = elapsed > 0 ? Double(counts.entries) / elapsed : 0
    let arenaBytes =
        tree.nodeCount * (4 + 4 + 4 + 8 + 8 + 8 + 4 + 4 + 2 + 1 + 4) + tree.nameBytes.count

    func topNodes(directories: Bool) -> [(Int32, UInt64)] {
        var picked: [(Int32, UInt64)] = []
        for node in 1..<Int32(tree.nodeCount) {
            let flags = tree.flags[Int(node)]
            let isDirectory = flags.contains(.directory)
            guard isDirectory == directories, !flags.contains(.smallFilesFold) else { continue }
            picked.append((node, tree.bytes[Int(node)]))
        }
        picked.sort { $0.1 > $1.1 }
        return Array(picked.prefix(top))
    }

    if json {
        var summary: [String: Any] = [
            "scope": scope.id, "root": snapshot.rootPath, "partial": snapshot.partial,
            "elapsedSeconds": elapsed, "entries": counts.entries, "entriesPerSecond": rate,
            "directories": counts.directories, "files": counts.files,
            "foldedFiles": counts.foldedFiles, "nodes": tree.nodeCount,
            "arenaBytes": arenaBytes, "peakRSS": peakRSS, "openFileDescriptors": openFDs,
            "scannedBytes": rec.scannedBytes, "sharedBytes": rec.sharedBytes,
            "unaccountedBytes": rec.unaccountedBytes, "overshootBytes": rec.overshootBytes,
            "notPermitted": counts.notPermitted, "dataVaults": counts.dataVaults,
            "accessDenied": counts.accessDenied,
            "unreadable": counts.unreadable, "vanished": counts.vanished,
            "datalessDirectories": counts.datalessDirectories,
            "datalessFiles": counts.datalessFiles, "separateVolumes": counts.separateVolumes,
            "hardLinkDuplicates": counts.hardLinkDuplicates,
            "sharedBlockFiles": counts.sharedBlockFiles, "entryErrors": counts.entryErrors,
            "smallFileThreshold": snapshot.smallFileThreshold, "workers": options.workerCount,
            "volumeChangedDuringScan": rec.volumeChangedDuringScan,
        ]
        if let used = rec.usedBytes { summary["usedBytes"] = used }
        if let purgeable = rec.purgeableBytes { summary["purgeableBytes"] = purgeable }
        if let snapshots = rec.localSnapshotCount { summary["localSnapshots"] = snapshots }
        summary["topDirectories"] = topNodes(directories: true).map {
            ["path": snapshot.displayPath(of: $0.0), "bytes": $0.1]
        }
        summary["topFiles"] = topNodes(directories: false).map {
            ["path": snapshot.displayPath(of: $0.0), "bytes": $0.1]
        }
        if let data = try? JSONSerialization.data(
            withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]),
            let text = String(data: data, encoding: .utf8)
        {
            print(text)
        }
        return
    }

    printSection("Scan" + (snapshot.partial ? " (cancelled, partial)" : ""))
    print("  root            : \(snapshot.rootPath)")
    print(String(format: "  elapsed         : %.1fs", elapsed))
    print("  entries         : \(counts.entries)  (\(Int(rate))/s)")
    print("  directories     : \(counts.directories)")
    print("  files           : \(counts.files) kept, \(counts.foldedFiles) folded")
    print(
        "  nodes           : \(tree.nodeCount)  (~\(ByteFormat.string(UInt64(arenaBytes))) arena)")
    print(
        "  fold threshold  : \(snapshot.smallFileThreshold) bytes, \(options.workerCount) workers")
    print("  peak RSS        : \(ByteFormat.string(peakRSS))")
    print("  open fds now    : \(openFDs)")

    printSection("Bytes")
    print("  scanned         : \(ByteFormat.string(rec.scannedBytes))  (\(rec.scannedBytes))")
    if let used = rec.usedBytes {
        print("  volume used     : \(ByteFormat.string(used))  (\(rec.volumeMountPoint))")
        print("  unaccounted     : \(ByteFormat.string(rec.unaccountedBytes))")
        if rec.overshootBytes > 0 {
            print(
                "  overshoot       : \(ByteFormat.string(rec.overshootBytes)) (clones counted in full)"
            )
        }
        if rec.volumeChangedDuringScan {
            print("  note            : volume changed during the scan")
        }
    }
    print("  shared blocks   : \(ByteFormat.string(rec.sharedBytes))")
    if let purgeable = rec.purgeableBytes {
        print("  purgeable       : \(ByteFormat.string(purgeable))")
    }
    if let snapshots = rec.localSnapshotCount { print("  local snapshots : \(snapshots)") }
    for volume in rec.systemVolumes {
        print(
            "  \(pad(volume.role.label.lowercased(), 16)): \(ByteFormat.string(volume.usedBytes))")
    }

    printSection("Exceptions")
    print("  not permitted   : \(counts.notPermitted) (EPERM, Full Disk Access)")
    print("  data vaults     : \(counts.dataVaults) (EPERM, entitlement only)")
    print("  access denied   : \(counts.accessDenied) (EACCES)")
    print("  unreadable      : \(counts.unreadable)   vanished: \(counts.vanished)")
    print("  dataless        : \(counts.datalessDirectories) dirs, \(counts.datalessFiles) files")
    print("  separate volumes: \(counts.separateVolumes)")
    print(
        "  hard-link dupes : \(counts.hardLinkDuplicates)   clone-flagged: \(counts.sharedBlockFiles)"
    )
    print("  entry errors    : \(counts.entryErrors)")

    if top > 0 {
        printSection("Largest directories")
        for (node, bytes) in topNodes(directories: true) {
            print("  " + pad(ByteFormat.string(bytes), 11) + snapshot.displayPath(of: node))
        }
        printSection("Largest files")
        for (node, bytes) in topNodes(directories: false) {
            print("  " + pad(ByteFormat.string(bytes), 11) + snapshot.displayPath(of: node))
        }
    }
    print("")
}

/// Sum of the .sqlite file and its -wal / -shm sidecars.
func databaseSizeOnDisk(_ url: URL) -> UInt64 {
    let paths = [url.path, url.path + "-wal", url.path + "-shm"]
    var total: UInt64 = 0
    for path in paths {
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
            let size = attrs[.size] as? UInt64
        {
            total += size
        }
    }
    return total
}

// MARK: - Output helpers

func printSection(_ title: String) {
    print("")
    print("== \(title) " + String(repeating: "=", count: max(0, 60 - title.count)))
}

func printCoverage(_ label: String, ok: Int, fail: Int, total: Int) {
    let pct = total > 0 ? Double(ok) / Double(total) * 100 : 0
    print(
        "  " + pad(label, 42) + pad("ok=\(ok)", 9) + pad("fail=\(fail)", 10)
            + String(format: "%.1f%%", pct))
}

func pad(_ string: String, _ width: Int) -> String {
    if string.count >= width { return string + " " }
    return string + String(repeating: " ", count: width - string.count)
}
