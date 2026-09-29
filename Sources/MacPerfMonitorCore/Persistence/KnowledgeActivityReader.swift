import Darwin
import Foundation
import GRDB

public enum KnowledgeActivityReader {
    public enum ReadError: Error, LocalizedError, Equatable {
        case notFound
        case permissionDenied
        case unsupportedSchema
        case tooManyRecords
        case unavailable

        public var errorDescription: String? {
            switch self {
            case .notFound:
                return t("Apple activity history is not available on this account.")
            case .permissionDenied:
                return t("Full Disk Access is required to read Apple activity history.")
            case .unsupportedSchema:
                return t("This version of Apple activity history is not supported.")
            case .tooManyRecords:
                return t("There are too many activity records. Choose a shorter timeframe.")
            case .unavailable:
                return t("Apple activity history could not be read. Check access and try again.")
            }
        }
    }

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Application Support/Knowledge/knowledgeC.db")
    }

    public static func read(
        bundleID: String, within range: ClosedRange<Date>, url: URL = defaultURL
    ) throws -> [UsageTimeline.Interval] {
        guard !bundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            range.lowerBound < range.upperBound,
            range.lowerBound.timeIntervalSinceReferenceDate.isFinite,
            range.upperBound.timeIntervalSinceReferenceDate.isFinite
        else { return [] }

        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            switch errno {
            case ENOENT: throw ReadError.notFound
            case EPERM, EACCES: throw ReadError.permissionDenied
            default: throw ReadError.unavailable
            }
        }
        Darwin.close(descriptor)

        do {
            var configuration = Configuration()
            configuration.readonly = true
            configuration.busyMode = .timeout(0.25)
            let database = try DatabaseQueue(path: url.path, configuration: configuration)
            return try database.read { db in
                try db.execute(sql: "PRAGMA query_only = ON; PRAGMA trusted_schema = OFF")
                guard try db.tableExists("ZOBJECT") else { throw ReadError.unsupportedSchema }
                let columns = Set(try db.columns(in: "ZOBJECT").map(\.name))
                guard
                    Set(["ZSTREAMNAME", "ZVALUESTRING", "ZSTARTDATE", "ZENDDATE"])
                        .isSubset(of: columns)
                else { throw ReadError.unsupportedSchema }

                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT ZSTREAMNAME, ZSTARTDATE, ZENDDATE FROM ZOBJECT
                        WHERE ZVALUESTRING = ?
                            AND ZSTREAMNAME IN ('/app/usage', '/app/mediaUsage')
                            AND typeof(ZSTARTDATE) IN ('real', 'integer')
                            AND typeof(ZENDDATE) IN ('real', 'integer')
                            AND ZENDDATE > ZSTARTDATE
                            AND ZENDDATE > ? AND ZSTARTDATE < ?
                        ORDER BY ZSTARTDATE, ZENDDATE
                        LIMIT 20001
                        """,
                    arguments: [
                        bundleID, range.lowerBound.timeIntervalSinceReferenceDate,
                        range.upperBound.timeIntervalSinceReferenceDate,
                    ])
                guard rows.count <= 20000 else { throw ReadError.tooManyRecords }
                let intervals = rows.map { row in
                    let stream: String = row["ZSTREAMNAME"]
                    return UsageTimeline.Interval(
                        kind: stream == "/app/usage" ? .appUsage : .mediaUsage,
                        start: Date(timeIntervalSinceReferenceDate: row["ZSTARTDATE"]),
                        end: Date(timeIntervalSinceReferenceDate: row["ZENDDATE"]))
                }
                return UsageTimeline.normalized(intervals, within: range)
            }
        } catch let error as ReadError {
            throw error
        } catch {
            throw ReadError.unavailable
        }
    }
}
