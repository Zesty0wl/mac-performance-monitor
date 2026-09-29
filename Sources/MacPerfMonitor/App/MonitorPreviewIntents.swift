import AppIntents
import Foundation
import MacPerfMonitorCore
import SwiftUI

enum MonitorReportKind: String, AppEnum {
    case overview, cpu, memory, disk, network

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Report"
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .overview: "System overview", .cpu: "CPU", .memory: "Memory",
        .disk: "Disk space", .network: "Network",
    ]

    var topic: AskTopic { AskTopic(rawValue: rawValue) ?? .overview }
}

struct MonitorReportEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Current monitor report"
    static var defaultQuery = MonitorReportQuery()

    var id: String
    @Property(title: "Summary") var summary: String
    @Property(title: "Evidence") var evidence: String
    @Property(title: "Limits") var limits: String
    @Property(title: "Captured at") var capturedAt: Date

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(summary)", subtitle: "Preview")
    }

    init(report: AskReport) {
        id = report.id.uuidString
        summary = report.summary
        evidence = report.evidence.map { "\($0.title): \($0.value). \($0.detail)" }.joined(
            separator: "\n")
        limits = report.limits.joined(separator: "\n")
        capturedAt = report.sampledAt ?? report.capturedAt
    }
}

struct MonitorReportQuery: EntityQuery {
    @Dependency private var runtime: MonitorIntentRuntime

    @MainActor
    func entities(for identifiers: [String]) async throws -> [MonitorReportEntity] {
        try runtime.resolve(identifiers)
    }
}

enum MonitorIntentError: LocalizedError {
    case consent, expired

    var errorDescription: String? {
        switch self {
        case .consent:
            return t(
                "Open Ask About This Mac (Preview) and enable sharing with Siri and Shortcuts first."
            )
        case .expired:
            return t("This preview report has expired. Request a new current report.")
        }
    }
}

@MainActor
final class MonitorIntentRuntime {
    private let defaults: UserDefaults
    private let read: (AskTopic) async throws -> AskReport
    private var reports: [(entity: MonitorReportEntity, createdAt: Date)] = []

    init(defaults: UserDefaults = .standard, read: @escaping (AskTopic) async throws -> AskReport) {
        self.defaults = defaults
        self.read = read
    }

    func currentReport(_ topic: AskTopic) async throws -> (AskReport, MonitorReportEntity) {
        try requireConsent()
        let report = try await read(topic)
        try Task.checkCancellation()
        try requireConsent()
        let entity = MonitorReportEntity(report: report)
        reports.removeAll { Date().timeIntervalSince($0.createdAt) > 300 }
        reports.append((entity, Date()))
        if reports.count > 8 { reports.removeFirst(reports.count - 8) }
        return (report, entity)
    }

    func resolve(_ identifiers: [String]) throws -> [MonitorReportEntity] {
        try requireConsent()
        reports.removeAll { Date().timeIntervalSince($0.createdAt) > 300 }
        let wanted = Set(identifiers.prefix(8))
        return reports.map(\.entity).filter { wanted.contains($0.id) }
    }

    func clear() { reports.removeAll() }

    private func requireConsent() throws {
        guard defaults.bool(forKey: AskPreviewPreferences.enabledKey),
            defaults.bool(forKey: AskPreviewPreferences.siriKey)
        else {
            clear()
            throw MonitorIntentError.consent
        }
    }
}

struct GetCurrentMonitorReportIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Current Monitor Report (Preview)"
    static var description = IntentDescription(
        "Read current system evidence without changing settings or using a language model.")
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "Report", default: .overview) var kind: MonitorReportKind
    @Dependency private var runtime: MonitorIntentRuntime

    static var parameterSummary: some ParameterSummary {
        Summary("Get the current \(\.$kind) report")
    }

    init() {}
    init(kind: MonitorReportKind) { self.kind = kind }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<MonitorReportEntity>
        & ProvidesDialog & ShowsSnippetView
    {
        let (report, entity) = try await runtime.currentReport(kind.topic)
        let facts = report.evidence.prefix(3).map { "\($0.title): \($0.value)." }.joined(
            separator: " ")
        let spoken = t("Preview. %@ %@", report.summary, facts)
        return .result(
            value: entity, dialog: IntentDialog(stringLiteral: spoken),
            view: VStack(alignment: .leading, spacing: 8) {
                Text("Preview").font(.caption).foregroundStyle(.secondary)
                Text(report.topic.title).font(.headline)
                Text(report.summary)
                ForEach(report.evidence.prefix(3)) { item in
                    HStack {
                        Text(item.title)
                        Spacer()
                        Text(item.value).monospacedDigit()
                    }
                }
                Text(report.capturedAt, format: .dateTime.hour().minute().second())
                    .font(.caption).foregroundStyle(.secondary)
                if let limit = report.limits.first {
                    Text(limit).font(.caption).foregroundStyle(.secondary)
                }
            })
    }
}

struct OpenAskPreviewIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Ask About This Mac (Preview)"
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        WindowOpenBridge.shared.open(id: WindowID.ask)
        return .result()
    }
}

struct MonitorPreviewShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: GetCurrentMonitorReportIntent(kind: .overview),
            phrases: ["Check my Mac with \(.applicationName)"],
            shortTitle: "System report", systemImageName: "gauge.with.dots.needle.50percent")
        AppShortcut(
            intent: GetCurrentMonitorReportIntent(kind: .cpu),
            phrases: ["Check CPU with \(.applicationName)"],
            shortTitle: "CPU report", systemImageName: "cpu")
        AppShortcut(
            intent: GetCurrentMonitorReportIntent(kind: .memory),
            phrases: ["Check memory with \(.applicationName)"],
            shortTitle: "Memory report", systemImageName: "memorychip")
        AppShortcut(
            intent: GetCurrentMonitorReportIntent(kind: .disk),
            phrases: ["Check disk space with \(.applicationName)"],
            shortTitle: "Disk space report", systemImageName: "internaldrive")
        AppShortcut(
            intent: GetCurrentMonitorReportIntent(kind: .network),
            phrases: ["Check network with \(.applicationName)"],
            shortTitle: "Network report", systemImageName: "network")
        AppShortcut(
            intent: OpenAskPreviewIntent(),
            phrases: ["Open Ask preview in \(.applicationName)"],
            shortTitle: "Ask preview", systemImageName: "sparkles")
    }
}

struct MonitorDestinationEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Monitor destination"
    static var defaultQuery = MonitorDestinationQuery()
    var id: String
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "Ask About This Mac (Preview)")
    }
}

struct MonitorDestinationQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [MonitorDestinationEntity] {
        identifiers.contains("ask-preview") ? [MonitorDestinationEntity(id: "ask-preview")] : []
    }

    func entities(matching string: String) async throws -> [MonitorDestinationEntity] {
        let name = t("Ask About This Mac (Preview)")
        return name.localizedStandardContains(string)
            ? [MonitorDestinationEntity(id: "ask-preview")] : []
    }

    func suggestedEntities() async throws -> [MonitorDestinationEntity] {
        [MonitorDestinationEntity(id: "ask-preview")]
    }
}

#if compiler(>=6.4)
@available(macOS 27.0, *)
@AppIntent(schema: .system.open)
struct OpenMonitorPreviewContentIntent: OpenIntent {
    var target: MonitorDestinationEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        guard target.id == "ask-preview" else { throw MonitorIntentError.expired }
        WindowOpenBridge.shared.open(id: WindowID.ask)
        return .result()
    }
}
#endif
