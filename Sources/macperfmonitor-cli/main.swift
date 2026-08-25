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
          macperfmonitor-cli help                       Show this help

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
