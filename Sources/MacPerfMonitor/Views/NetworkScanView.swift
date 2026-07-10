import AppKit
import Combine
import MacPerfMonitorCore
import SwiftUI

struct NetworkScanView: View {
    let networkInfo: NetworkInfo
    var dismiss: () -> Void = {}

    @StateObject private var model = NetworkScanViewModel()
    @State private var selection: Set<String> = []
    @State private var searchText = ""
    @State private var showsConfiguration = false
    @State private var showsDetails = true
    @State private var portConfigurationTarget: NetworkPortScanTarget?
    @State private var didRequestInitialScan = false
    @State private var sortOrder = [
        KeyPathComparator(\NetworkScanRow.ipv4SortValue)
    ]
    @AppStorage("networkScanShowIPv6") private var showIPv6 = false

    private var interfaceChoices: [NetworkScanInterfaceChoice] {
        networkInfo.listedInterfaces.compactMap { adapter in
            guard
                let address = adapter.addresses.first(where: {
                    $0.family == .ipv4 && !$0.isLinkLocal
                        && !$0.address.hasPrefix("169.254.")
                })
            else { return nil }
            return NetworkScanInterfaceChoice(
                bsdName: adapter.bsdName,
                displayName: adapter.displayName,
                ipv4Address: address.address,
                prefixLength: address.prefixLength,
                macAddress: adapter.macAddress,
                gateway: adapter.bsdName == networkInfo.primaryInterface
                    ? networkInfo.router : nil)
        }
    }

    private var visibleRows: [NetworkScanRow] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let rows = query.isEmpty ? model.rows : model.rows.filter { $0.searchText.contains(query) }
        return rows.sorted(using: sortOrder)
    }

    private var selectedAddress: String? { selection.count == 1 ? selection.first : nil }

    private var tableContentWidth: CGFloat { showIPv6 ? 2_180 : 1_800 }

    var body: some View {
        VStack(spacing: 0) {
            scanToolbar
            Divider()
            HSplitView {
                results
                    .frame(
                        minWidth: showsDetails ? 560 : 800,
                        maxWidth: .infinity,
                        maxHeight: .infinity)
                if showsDetails {
                    details
                        .frame(
                            minWidth: 250, idealWidth: 285, maxWidth: 340,
                            maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .layoutPriority(1)
            Divider()
            statusBar
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear(perform: prepareAndStartIfNeeded)
        .onChange(of: networkInfo) { _, _ in prepareAndStartIfNeeded() }
        .onChange(of: showIPv6) { _, enabled in
            if !enabled {
                sortOrder = [KeyPathComparator(\NetworkScanRow.ipv4SortValue)]
            }
        }
        .onDisappear { model.stopAll() }
        .sheet(isPresented: $showsConfiguration) {
            NetworkScanConfigurationSheet(
                choices: interfaceChoices,
                configuration: model.configuration,
                onScan: { configuration in
                    model.setConfiguration(configuration)
                    model.startScan()
                })
        }
        .sheet(item: $portConfigurationTarget) { target in
            NetworkPortScanConfigurationSheet(address: target.address) { ports in
                model.startPortScan(address: target.address, ports: ports)
            }
        }
        .alert(
            "Network Scan",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "The scan could not be completed.")
        }
    }

    private var scanToolbar: some View {
        HStack(spacing: 10) {
            Button(action: dismiss) {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.borderless)
            .help("Return to Network")

            VStack(alignment: .leading, spacing: 1) {
                Text("Network Scan").font(.headline)
                Text(model.scanSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            if model.isScanning {
                Button {
                    model.stopScan()
                } label: {
                    Image(systemName: "stop.fill")
                }
                .buttonStyle(.borderedProminent)
                .help("Stop network scan")
            } else {
                Button {
                    model.startScan()
                } label: {
                    Image(systemName: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.configuration == nil)
                .keyboardShortcut("r", modifiers: .command)
                .help("Start network scan")
            }

            Button {
                showsConfiguration = true
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .buttonStyle(.borderless)
            .disabled(interfaceChoices.isEmpty)
            .help("Configure interface and subnet range")

            Menu {
                if let selectedAddress {
                    Button("Start Port Scan") {
                        model.startPortScan(
                            address: selectedAddress, ports: NetworkScanViewModel.commonPorts)
                    }
                    Button("Configure Port Scan...") {
                        portConfigurationTarget = NetworkPortScanTarget(address: selectedAddress)
                    }
                }
            } label: {
                Image(systemName: "point.3.connected.trianglepath.dotted")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .disabled(selectedAddress == nil || model.configuration == nil)
            .help("Port scan the selected device")

            Button {
                model.clearResults()
                selection.removeAll()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Clear results")
            .disabled(model.rows.isEmpty)

            Toggle("IPv6", isOn: $showIPv6)
                .toggleStyle(.checkbox)
                .help("Show IPv6 Local and IPv6 Global columns")

            TextField("Search", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 150)

            Button {
                showsDetails.toggle()
            } label: {
                Image(systemName: "sidebar.right")
            }
            .buttonStyle(.borderless)
            .help(showsDetails ? "Hide details" : "Show details")
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
    }

    private var results: some View {
        GeometryReader { geometry in
            ScrollView(.horizontal) {
                ZStack {
                    deviceTable
                    if model.rows.isEmpty && !model.isScanning {
                        ContentUnavailableView(
                            "No devices yet",
                            systemImage: "network",
                            description: Text(
                                model.configuration == nil
                                    ? "Connect an IPv4 interface to scan your local network."
                                    : "Choose Scan to discover devices on the selected subnet.")
                        )
                        .allowsHitTesting(false)
                    }
                }
                .frame(
                    width: max(geometry.size.width, tableContentWidth),
                    height: geometry.size.height)
            }
            .scrollIndicators(.visible)
        }
    }

    private var deviceTable: some View {
        Table(visibleRows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("IPv4 address", value: \.ipv4SortValue) { row in
                HStack(spacing: 7) {
                    Circle()
                        .fill(row.host.isReachable ? Color.green : Color.secondary)
                        .frame(width: 7, height: 7)
                    Text(row.host.ipv4Address).font(.body.monospacedDigit())
                }
            }
            .width(min: 125, ideal: 145)

            if showIPv6 {
                TableColumn("IPv6 Local", value: \.ipv6LocalSortValue) { row in
                    tableText(
                        row.host.ipv6LocalAddresses.joined(separator: ", "), monospaced: true)
                }
                .width(min: 150, ideal: 190)

                TableColumn("IPv6 Global", value: \.ipv6GlobalSortValue) { row in
                    tableText(
                        row.host.ipv6GlobalAddresses.joined(separator: ", "), monospaced: true)
                }
                .width(min: 150, ideal: 190)
            }

            TableColumn("MAC address", value: \.macSortValue) { row in
                tableText(row.host.macAddress, monospaced: true)
            }
            .width(min: 132, ideal: 145)

            TableColumn("Hostname", value: \.hostNameSortValue) { row in
                tableText(row.displayHostName)
            }
            .width(min: 125, ideal: 155)

            TableColumn("Ping", value: \.reachabilitySortValue) { row in
                Image(systemName: "circle.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(row.host.isReachable ? .green : .secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .help(row.host.isReachable ? "Reachable" : "Not reachable")
            }
            .width(min: 44, ideal: 50, max: 58)

            secondaryColumns()
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contextMenu(forSelectionType: String.self) { ids in
            if ids.count == 1, let address = ids.first {
                Button("Start Port Scan") {
                    model.startPortScan(address: address, ports: NetworkScanViewModel.commonPorts)
                }
                .disabled(model.configuration == nil)
                Button("Configure Port Scan...") {
                    portConfigurationTarget = NetworkPortScanTarget(address: address)
                }
                .disabled(model.configuration == nil)
                Divider()
                Button("Copy IP Address") { copy(address) }
                if let mac = model.row(withID: address)?.host.macAddress {
                    Button("Copy MAC Address") { copy(mac) }
                }
            }
        } primaryAction: { ids in
            selection = ids
            showsDetails = true
        }
    }

    @TableColumnBuilder<NetworkScanRow, KeyPathComparator<NetworkScanRow>>
    private func secondaryColumns()
        -> some TableColumnContent<NetworkScanRow, KeyPathComparator<NetworkScanRow>>
    {
        TableColumn("Vendor", value: \.vendorSortValue) { row in
            vendorCell(row)
        }
        .width(min: 130, ideal: 165)

        TableColumn("Identification", value: \.identificationSortValue) { row in
            tableText(row.host.identification)
        }
        .width(min: 130, ideal: 170)

        TableColumn("DNS Name", value: \.dnsSortValue) { row in
            tableText(row.host.dnsName)
        }
        .width(min: 130, ideal: 165)

        TableColumn("mDNS Name", value: \.mdnsSortValue) { row in
            tableText(row.host.mdnsName)
        }
        .width(min: 130, ideal: 165)

        TableColumn("SMB Name", value: \.smbNameSortValue) { row in
            tableText(row.host.smbName)
        }
        .width(min: 100, ideal: 130)

        TableColumn("SMB Domain", value: \.smbDomainSortValue) { row in
            tableText(row.host.smbDomain)
        }
        .width(min: 105, ideal: 130)

        TableColumn("TCP Ports", value: \.portSortValue) { row in
            tableText(row.portSummary, monospaced: true)
        }
        .width(min: 125, ideal: 175)

        TableColumn("Comments", value: \.commentsSortValue) { row in
            tableText(row.comments)
        }
        .width(min: 140, ideal: 190)
    }

    @ViewBuilder private func tableText(_ value: String?, monospaced: Bool = false) -> some View {
        let text = value?.isEmpty == false ? value! : ""
        if monospaced {
            Text(text)
                .font(.body.monospacedDigit())
                .lineLimit(1)
                .truncationMode(.middle)
                .help(text)
        } else {
            Text(text)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(text)
        }
    }

    @ViewBuilder private func vendorCell(_ row: NetworkScanRow) -> some View {
        if let vendor = row.host.vendor, !vendor.isEmpty {
            tableText(vendor)
        } else if row.host.macAddress == nil {
            Text("No MAC address")
                .foregroundStyle(.tertiary)
        } else if NetworkMACAddress.kind(row.host.macAddress) == .locallyAdministered {
            Text("Private / randomized")
                .foregroundStyle(.secondary)
                .help("This locally administered MAC address does not contain an IEEE vendor ID.")
        } else if NetworkMACAddress.kind(row.host.macAddress) == .multicast {
            Text("Multicast")
                .foregroundStyle(.secondary)
        } else {
            switch model.vendorLookupState {
            case .notStarted:
                Text("Not checked")
                    .foregroundStyle(.tertiary)
            case .waiting:
                HStack(spacing: 6) {
                    Image(systemName: "clock")
                    Text("Queued")
                }
                .foregroundStyle(.secondary)
            case .searching:
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                    Text("Looking up...")
                }
                .foregroundStyle(.secondary)
            case .finished:
                Text("Not found")
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder private var details: some View {
        if let address = selectedAddress, let row = model.row(withID: address) {
            NetworkScanDetailsView(
                row: row,
                hostName: Binding(
                    get: { model.row(withID: address)?.customHostName ?? "" },
                    set: { model.setCustomHostName($0, for: address) }),
                comments: Binding(
                    get: { model.row(withID: address)?.comments ?? "" },
                    set: { model.setComments($0, for: address) }),
                startPortScan: {
                    model.startPortScan(address: address, ports: NetworkScanViewModel.commonPorts)
                })
        } else {
            ContentUnavailableView(
                "No Selection",
                systemImage: "cursorarrow.click.2",
                description: Text("Select a device to inspect its details."))
        }
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            if model.isScanning {
                ProgressView(value: model.progressFraction)
                    .progressViewStyle(.linear)
                    .frame(width: 120)
            } else if model.vendorLookupState == .waiting
                || model.vendorLookupState == .searching
            {
                ProgressView().controlSize(.small)
            }
            Text(model.statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Text("Devices seen: \(model.rows.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .frame(height: 30)
    }

    private func prepareAndStartIfNeeded() {
        model.prepare(
            choices: interfaceChoices, primaryInterface: networkInfo.primaryInterface)
        guard !didRequestInitialScan, model.configuration != nil else { return }
        didRequestInitialScan = true
        model.startScan()
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

// MARK: - View model

@MainActor
private final class NetworkScanViewModel: ObservableObject {
    enum VendorLookupState {
        case notStarted
        case waiting
        case searching
        case finished
    }

    static let commonPorts: [UInt16] = [
        20, 21, 22, 23, 25, 53, 80, 110, 135, 139, 143, 443, 445, 515, 548,
        631, 993, 995, 1883, 2049, 3389, 5000, 5900, 8008, 8080, 8443, 9100,
    ]

    @Published private(set) var rows: [NetworkScanRow] = []
    @Published private(set) var configuration: NetworkScanConfiguration?
    @Published private(set) var progress = NetworkScanProgress(
        phase: .finished, completedAddressCount: 0, totalAddressCount: 0, deviceCount: 0)
    @Published private(set) var isScanning = false
    @Published private(set) var vendorLookupState = VendorLookupState.notStarted
    @Published var errorMessage: String?

    private let scanner = NetworkScanner()
    private let bonjour = NetworkBonjourDiscovery()
    private let annotations = NetworkDeviceAnnotationStore()
    private var scanTask: Task<Void, Never>?
    private var scanID = UUID()
    private var portScanTasks: [String: Task<Void, Never>] = [:]
    private var bonjourObservations: [String: NetworkBonjourObservation] = [:]

    var scanSubtitle: String {
        guard let configuration else { return "No active IPv4 interface" }
        return
            "\(configuration.interfaceName)  \(configuration.fromIPv4Address) to "
            + configuration.toIPv4Address
    }

    var progressFraction: Double {
        guard progress.totalAddressCount > 0 else { return 0 }
        return min(
            Double(progress.completedAddressCount) / Double(progress.totalAddressCount), 1)
    }

    var statusText: String {
        if isScanning {
            switch progress.phase {
            case .discovering:
                return
                    "Discovering \(progress.completedAddressCount) of "
                    + "\(progress.totalAddressCount) addresses"
            case .identifying:
                return "Identifying \(progress.deviceCount) devices"
            case .finished:
                return "Finishing scan"
            }
        }
        if vendorLookupState == .waiting || vendorLookupState == .searching {
            return "Devices found · Looking up vendors..."
        }
        if progress.totalAddressCount > 0 {
            return "Scan complete"
        }
        return configuration == nil ? "No interface available" : "Ready to scan"
    }

    func prepare(choices: [NetworkScanInterfaceChoice], primaryInterface: String?) {
        if let configuration,
            choices.contains(where: {
                $0.bsdName == configuration.interfaceName
                    && $0.ipv4Address == configuration.localIPv4Address
            })
        {
            return
        }
        guard
            let choice = choices.first(where: { $0.bsdName == primaryInterface }) ?? choices.first,
            let range = choice.suggestedRange
        else {
            configuration = nil
            return
        }
        configuration = choice.configuration(from: range.from, to: range.to)
    }

    func setConfiguration(_ configuration: NetworkScanConfiguration) {
        self.configuration = configuration
    }

    func startScan() {
        guard let configuration else { return }
        stopScan()
        rows.removeAll()
        bonjourObservations.removeAll()
        errorMessage = nil
        isScanning = true
        vendorLookupState = .waiting
        progress = NetworkScanProgress(
            phase: .discovering, completedAddressCount: 0,
            totalAddressCount: (try? configuration.addresses().count) ?? 0,
            deviceCount: 0)
        let currentID = UUID()
        scanID = currentID
        AppLog.ui.notice(
            "Network scan started on \(configuration.interfaceName, privacy: .public): \(configuration.fromIPv4Address, privacy: .public) to \(configuration.toIPv4Address, privacy: .public)"
        )
        bonjour.start { [weak self] observation in
            self?.apply(observation)
        }
        let events = scanner.scan(configuration)
        scanTask = Task { [weak self] in
            guard let self else { return }
            for await event in events {
                guard !Task.isCancelled, scanID == currentID else { return }
                apply(event)
            }
            if scanID == currentID {
                isScanning = false
                scanTask = nil
            }
        }
    }

    func stopScan() {
        scanID = UUID()
        scanTask?.cancel()
        scanTask = nil
        bonjour.stop()
        isScanning = false
        if vendorLookupState == .waiting || vendorLookupState == .searching {
            vendorLookupState = .notStarted
        }
    }

    func stopAll() {
        stopScan()
        for task in portScanTasks.values { task.cancel() }
        portScanTasks.removeAll()
    }

    func clearResults() {
        stopScan()
        for task in portScanTasks.values { task.cancel() }
        portScanTasks.removeAll()
        rows.removeAll()
        vendorLookupState = .notStarted
        progress = NetworkScanProgress(
            phase: .finished, completedAddressCount: 0,
            totalAddressCount: 0, deviceCount: 0)
    }

    func row(withID id: String) -> NetworkScanRow? {
        rows.first { $0.id == id }
    }

    func setCustomHostName(_ name: String, for address: String) {
        updateRow(address) {
            $0.customHostName = name
            annotations.set(hostName: name, comments: $0.comments, for: $0.host)
        }
    }

    func setComments(_ comments: String, for address: String) {
        updateRow(address) {
            $0.comments = comments
            annotations.set(hostName: $0.customHostName, comments: comments, for: $0.host)
        }
    }

    func startPortScan(address: String, ports: [UInt16]) {
        guard let interfaceName = configuration?.interfaceName else { return }
        portScanTasks[address]?.cancel()
        AppLog.ui.notice(
            "Network port scan started for \(address, privacy: .public), \(ports.count) ports")
        updateRow(address) {
            $0.isPortScanning = true
            $0.didPortScan = true
            $0.openPorts = []
        }
        let task = Task { [weak self] in
            guard let self else { return }
            let openPorts = await scanner.scanPorts(
                host: address, interfaceName: interfaceName, ports: ports)
            guard !Task.isCancelled else { return }
            updateRow(address) {
                $0.isPortScanning = false
                $0.openPorts = openPorts
            }
            let openCount = openPorts.count
            AppLog.ui.notice(
                "Network port scan finished for \(address, privacy: .public): \(openCount) open")
            portScanTasks[address] = nil
        }
        portScanTasks[address] = task
    }

    private func apply(_ event: NetworkScanEvent) {
        switch event {
        case .host(let host):
            var enrichedHost = host
            if let observation = bonjourObservations[host.ipv4Address] {
                Self.merge(observation, into: &enrichedHost)
            }
            if let index = rows.firstIndex(where: { $0.id == host.id }) {
                rows[index].host = enrichedHost
            } else {
                let annotation = annotations.annotation(for: enrichedHost)
                rows.append(
                    NetworkScanRow(
                        host: enrichedHost,
                        customHostName: annotation?.hostName ?? "",
                        comments: annotation?.comments ?? ""))
            }
            rows.sort {
                (NetworkIPv4Address.value($0.host.ipv4Address) ?? 0)
                    < (NetworkIPv4Address.value($1.host.ipv4Address) ?? 0)
            }
        case .progress(let progress):
            self.progress = progress
            if progress.phase == .finished {
                isScanning = false
                AppLog.ui.notice(
                    "Network scan discovered \(progress.deviceCount) devices")
            }
        case .vendorLookupStarted:
            vendorLookupState = .searching
            AppLog.ui.notice("Network vendor lookup started")
        case .vendors(let vendors):
            var updatedRows = rows
            for index in updatedRows.indices {
                if let vendor = vendors[updatedRows[index].id] {
                    updatedRows[index].host.vendor = vendor
                }
            }
            rows = updatedRows
        case .vendorLookupFinished:
            vendorLookupState = .finished
            AppLog.ui.notice("Network vendor lookup finished")
        case .failed(let message):
            errorMessage = message
            isScanning = false
            vendorLookupState = .notStarted
            AppLog.ui.error("Network scan failed: \(message, privacy: .public)")
        }
    }

    private func apply(_ observation: NetworkBonjourObservation) {
        let previous = bonjourObservations[observation.ipv4Address]
        let preferred: NetworkBonjourObservation
        if let previous, previous.identificationPriority > observation.identificationPriority {
            preferred = NetworkBonjourObservation(
                ipv4Address: observation.ipv4Address,
                mdnsName: observation.mdnsName ?? previous.mdnsName,
                identification: previous.identification,
                identificationPriority: previous.identificationPriority)
        } else {
            preferred = NetworkBonjourObservation(
                ipv4Address: observation.ipv4Address,
                mdnsName: observation.mdnsName ?? previous?.mdnsName,
                identification: observation.identification ?? previous?.identification,
                identificationPriority: observation.identification == nil
                    ? previous?.identificationPriority ?? 0
                    : observation.identificationPriority)
        }
        bonjourObservations[observation.ipv4Address] = preferred
        updateRow(observation.ipv4Address) { row in
            Self.merge(preferred, into: &row.host)
        }
    }

    private static func merge(
        _ observation: NetworkBonjourObservation, into host: inout NetworkScanHost
    ) {
        if let mdnsName = observation.mdnsName {
            host.mdnsName = mdnsName
            host.hostName = host.hostName ?? mdnsName
        }
        if let identification = observation.identification {
            host.identification = identification
        }
    }

    private func updateRow(_ address: String, mutation: (inout NetworkScanRow) -> Void) {
        guard let index = rows.firstIndex(where: { $0.id == address }) else { return }
        mutation(&rows[index])
    }
}

private struct NetworkScanRow: Identifiable, Equatable {
    var host: NetworkScanHost
    var customHostName = ""
    var comments = ""
    var openPorts: [NetworkOpenPort] = []
    var isPortScanning = false
    var didPortScan = false

    var id: String { host.id }

    var ipv4SortValue: UInt32 { NetworkIPv4Address.value(host.ipv4Address) ?? .max }
    var ipv6LocalSortValue: String { host.ipv6LocalAddresses.joined(separator: " ").lowercased() }
    var ipv6GlobalSortValue: String {
        host.ipv6GlobalAddresses.joined(separator: " ").lowercased()
    }
    var macSortValue: String { host.macAddress?.lowercased() ?? "" }
    var hostNameSortValue: String { displayHostName?.lowercased() ?? "" }
    var reachabilitySortValue: Int { host.isReachable ? 1 : 0 }
    var vendorSortValue: String {
        if let vendor = host.vendor { return vendor.lowercased() }
        switch NetworkMACAddress.kind(host.macAddress) {
        case .locallyAdministered: return "private / randomized"
        case .multicast: return "multicast"
        default: return ""
        }
    }
    var identificationSortValue: String { host.identification?.lowercased() ?? "" }
    var dnsSortValue: String { host.dnsName?.lowercased() ?? "" }
    var mdnsSortValue: String { host.mdnsName?.lowercased() ?? "" }
    var smbNameSortValue: String { host.smbName?.lowercased() ?? "" }
    var smbDomainSortValue: String { host.smbDomain?.lowercased() ?? "" }
    var portSortValue: String { portSummary?.lowercased() ?? "" }
    var commentsSortValue: String { comments.lowercased() }

    var displayHostName: String? {
        let custom = customHostName.trimmingCharacters(in: .whitespacesAndNewlines)
        return custom.isEmpty ? host.hostName : custom
    }

    var portSummary: String? {
        if isPortScanning { return "Scanning..." }
        if !openPorts.isEmpty {
            return openPorts.map { "\($0.port) \($0.serviceName)" }.joined(separator: ", ")
        }
        return didPortScan ? "None found" : nil
    }

    var searchText: String {
        [
            host.ipv4Address,
            host.ipv6LocalAddresses.joined(separator: " "),
            host.ipv6GlobalAddresses.joined(separator: " "),
            host.macAddress,
            displayHostName,
            host.vendor,
            host.identification,
            host.dnsName,
            host.mdnsName,
            host.smbName,
            host.smbDomain,
            portSummary,
            comments,
        ]
        .compactMap { $0 }
        .joined(separator: " ")
        .lowercased()
    }
}

private struct NetworkDeviceAnnotation: Codable {
    var hostName: String
    var comments: String
}

private final class NetworkDeviceAnnotationStore {
    private static let defaultsKey = "networkScanDeviceAnnotations"
    private static let legacyDefaultsKey = "lanScanDeviceAnnotations"
    private var values: [String: NetworkDeviceAnnotation]

    init() {
        let defaults = UserDefaults.standard
        let data =
            defaults.data(forKey: Self.defaultsKey)
            ?? defaults.data(forKey: Self.legacyDefaultsKey)
        if let data,
            let decoded = try? JSONDecoder().decode(
                [String: NetworkDeviceAnnotation].self, from: data)
        {
            values = decoded
            if defaults.data(forKey: Self.defaultsKey) == nil {
                defaults.set(data, forKey: Self.defaultsKey)
            }
        } else {
            values = [:]
        }
    }

    func annotation(for host: NetworkScanHost) -> NetworkDeviceAnnotation? {
        values[key(for: host)]
    }

    func set(hostName: String, comments: String, for host: NetworkScanHost) {
        let key = key(for: host)
        if hostName.isEmpty && comments.isEmpty {
            values[key] = nil
        } else {
            values[key] = NetworkDeviceAnnotation(hostName: hostName, comments: comments)
        }
        if let data = try? JSONEncoder().encode(values) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    private func key(for host: NetworkScanHost) -> String {
        host.macAddress ?? host.ipv4Address
    }
}

// MARK: - Bonjour enrichment

private struct NetworkBonjourObservation: Sendable {
    var ipv4Address: String
    var mdnsName: String?
    var identification: String?
    var identificationPriority: Int
}

@MainActor
private final class NetworkBonjourDiscovery {
    private var worker: NetworkBonjourWorker?
    private var generation = UUID()

    func start(onObservation: @escaping (NetworkBonjourObservation) -> Void) {
        stop()
        let currentGeneration = UUID()
        generation = currentGeneration
        let worker = NetworkBonjourWorker { [weak self] observation in
            DispatchQueue.main.async {
                guard self?.generation == currentGeneration else { return }
                onObservation(observation)
            }
        }
        self.worker = worker
        worker.start()
    }

    func stop() {
        generation = UUID()
        worker?.stop()
        worker = nil
    }
}

private final class NetworkBonjourWorker: NSObject, NetServiceBrowserDelegate,
    NetServiceDelegate, @unchecked Sendable
{
    private static let serviceTypes = [
        "_airplay._tcp.",
        "_raop._tcp.",
        "_googlecast._tcp.",
        "_sonos._tcp.",
        "_spotify-connect._tcp.",
        "_device-info._tcp.",
        "_workstation._tcp.",
        "_smb._tcp.",
        "_afpovertcp._tcp.",
        "_ssh._tcp.",
        "_ipp._tcp.",
        "_printer._tcp.",
        "_http._tcp.",
        "_https._tcp.",
        "_homekit._tcp.",
        "_hap._tcp.",
    ]

    private let onObservation: (NetworkBonjourObservation) -> Void
    private var browsers: [NetServiceBrowser] = []
    private var services: [ObjectIdentifier: NetService] = [:]
    private var thread: Thread?

    init(onObservation: @escaping (NetworkBonjourObservation) -> Void) {
        self.onObservation = onObservation
    }

    func start() {
        guard thread == nil else { return }
        let thread = Thread { [weak self] in self?.run() }
        thread.name = "uk.co.bzwrd.macperfmonitor.bonjour"
        thread.qualityOfService = .utility
        self.thread = thread
        thread.start()
    }

    func stop() {
        thread?.cancel()
        thread = nil
    }

    private func run() {
        let deadline = Date().addingTimeInterval(5)
        for serviceType in Self.serviceTypes {
            let browser = NetServiceBrowser()
            browser.delegate = self
            browser.searchForServices(ofType: serviceType, inDomain: "local.")
            browsers.append(browser)
        }

        while !Thread.current.isCancelled, Date() < deadline {
            _ = RunLoop.current.run(
                mode: .default,
                before: min(deadline, Date().addingTimeInterval(0.1)))
        }

        for browser in browsers { browser.stop() }
        for service in services.values {
            service.stop()
            service.delegate = nil
        }
        browsers.removeAll()
        services.removeAll()
    }

    func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didFind service: NetService,
        moreComing: Bool
    ) {
        service.delegate = self
        services[ObjectIdentifier(service)] = service
        service.resolve(withTimeout: 3)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        let mdnsName = sender.hostName.map(Self.trimmedDNSName)
        let identification = Self.identification(for: sender)
        let priority = Self.priority(for: sender.type)
        for address in Self.ipv4Addresses(from: sender.addresses ?? []) {
            onObservation(
                NetworkBonjourObservation(
                    ipv4Address: address,
                    mdnsName: mdnsName,
                    identification: identification,
                    identificationPriority: priority))
        }
        sender.stop()
        sender.delegate = nil
        services[ObjectIdentifier(sender)] = nil
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        sender.stop()
        sender.delegate = nil
        services[ObjectIdentifier(sender)] = nil
    }

    private static func ipv4Addresses(from addresses: [Data]) -> Set<String> {
        var result: Set<String> = []
        for data in addresses {
            let address = data.withUnsafeBytes { raw -> String? in
                guard let base = raw.baseAddress else { return nil }
                let socketAddress = base.assumingMemoryBound(to: sockaddr.self)
                guard socketAddress.pointee.sa_family == sa_family_t(AF_INET) else { return nil }
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                guard
                    getnameinfo(
                        socketAddress, socklen_t(data.count), &host, socklen_t(host.count),
                        nil, 0, NI_NUMERICHOST) == 0
                else { return nil }
                return String(cString: host)
            }
            if let address { result.insert(address) }
        }
        return result
    }

    private static func identification(for service: NetService) -> String? {
        let name = service.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let txt = NetService.dictionary(fromTXTRecord: service.txtRecordData() ?? Data())
        let modelKeys = ["model", "md", "am", "ty"]
        let model = modelKeys.lazy.compactMap { key in
            txt[key].flatMap { String(data: $0, encoding: .utf8) }
        }.first?.trimmingCharacters(in: .whitespacesAndNewlines)

        let usefulName = isUsefulServiceName(name) ? name : nil
        if let usefulName, let model, !model.isEmpty,
            !usefulName.localizedCaseInsensitiveContains(model)
        {
            return "\(usefulName), \(model)"
        }
        return usefulName ?? model
    }

    private static func isUsefulServiceName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 96 else { return false }
        let compact = name.filter { $0.isHexDigit || $0 == "-" }
        return compact.count < name.count || name.contains(" ")
    }

    private static func priority(for type: String) -> Int {
        switch type {
        case "_airplay._tcp.", "_googlecast._tcp.", "_sonos._tcp.", "_homekit._tcp.",
            "_hap._tcp.":
            return 3
        case "_device-info._tcp.", "_workstation._tcp.", "_ipp._tcp.", "_printer._tcp.":
            return 2
        default:
            return 1
        }
    }

    private static func trimmedDNSName(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }
}

// MARK: - Details

private struct NetworkScanDetailsView: View {
    let row: NetworkScanRow
    @Binding var hostName: String
    @Binding var comments: String
    var startPortScan: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.displayHostName ?? row.host.ipv4Address)
                        .font(.title3.weight(.semibold))
                        .lineLimit(2)
                    Text(row.host.ipv4Address)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                detailSection("Identity") {
                    detail("MAC", row.host.macAddress)
                    detail("Vendor", row.host.vendor)
                    detail("Identification", row.host.identification)
                    detail("DNS", row.host.dnsName)
                    detail("mDNS", row.host.mdnsName)
                    detail("SMB", row.host.smbName)
                    detail("Domain", row.host.smbDomain)
                }

                if !row.host.ipv6LocalAddresses.isEmpty || !row.host.ipv6GlobalAddresses.isEmpty {
                    detailSection("IPv6") {
                        detail("Local", row.host.ipv6LocalAddresses.joined(separator: ", "))
                        detail("Global", row.host.ipv6GlobalAddresses.joined(separator: ", "))
                    }
                }

                detailSection("TCP Ports") {
                    if row.isPortScanning {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Scanning...").foregroundStyle(.secondary)
                        }
                    } else if row.didPortScan {
                        if row.openPorts.isEmpty {
                            Text("No open ports found in the selected set.")
                                .font(.callout).foregroundStyle(.secondary)
                        } else {
                            ForEach(row.openPorts) { port in
                                HStack {
                                    Text("\(port.port)").font(.callout.monospacedDigit())
                                    Text(port.serviceName).font(.callout).foregroundStyle(
                                        .secondary)
                                    Spacer()
                                }
                            }
                        }
                    }
                    Button("Scan Common Ports", action: startPortScan)
                        .disabled(row.isPortScanning)
                }

                detailSection("Device Label") {
                    TextField("Detected name", text: $hostName)
                }

                detailSection("Comments") {
                    TextEditor(text: $comments)
                        .font(.callout)
                        .frame(height: 72)
                        .padding(4)
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 0.5))
                }
            }
            .padding(14)
        }
    }

    @ViewBuilder private func detailSection(
        _ title: String, @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    @ViewBuilder private func detail(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.caption2).foregroundStyle(.tertiary)
                Text(value).font(.callout).textSelection(.enabled)
            }
        }
    }
}

// MARK: - Scan configuration

private struct NetworkScanInterfaceChoice: Identifiable, Hashable {
    var bsdName: String
    var displayName: String
    var ipv4Address: String
    var prefixLength: Int?
    var macAddress: String?
    var gateway: String?

    var id: String { "\(bsdName)-\(ipv4Address)" }

    var suggestedRange: (from: String, to: String)? {
        NetworkIPv4Address.suggestedRange(address: ipv4Address, prefixLength: prefixLength)
    }

    func configuration(from: String, to: String) -> NetworkScanConfiguration {
        NetworkScanConfiguration(
            interfaceName: bsdName,
            localIPv4Address: ipv4Address,
            localMACAddress: macAddress,
            fromIPv4Address: from,
            toIPv4Address: to)
    }

    var mask: String? {
        guard let prefixLength else { return nil }
        let prefix = min(max(prefixLength, 0), 32)
        let value = prefix == 0 ? UInt32(0) : UInt32.max << UInt32(32 - prefix)
        return NetworkIPv4Address.string(value)
    }
}

private struct NetworkScanConfigurationSheet: View {
    let choices: [NetworkScanInterfaceChoice]
    let configuration: NetworkScanConfiguration?
    let onScan: (NetworkScanConfiguration) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: String
    @State private var fromAddress: String
    @State private var toAddress: String

    init(
        choices: [NetworkScanInterfaceChoice],
        configuration: NetworkScanConfiguration?,
        onScan: @escaping (NetworkScanConfiguration) -> Void
    ) {
        self.choices = choices
        self.configuration = configuration
        self.onScan = onScan
        let selected =
            choices.first(where: {
                $0.bsdName == configuration?.interfaceName
                    && $0.ipv4Address == configuration?.localIPv4Address
            }) ?? choices.first
        _selectedID = State(initialValue: selected?.id ?? "")
        _fromAddress = State(
            initialValue: configuration?.fromIPv4Address ?? selected?.suggestedRange?.from ?? "")
        _toAddress = State(
            initialValue: configuration?.toIPv4Address ?? selected?.suggestedRange?.to ?? "")
    }

    private var selectedChoice: NetworkScanInterfaceChoice? {
        choices.first { $0.id == selectedID }
    }

    private var candidate: NetworkScanConfiguration? {
        selectedChoice?.configuration(from: fromAddress, to: toAddress)
    }

    private var validationMessage: String? {
        guard let candidate else { return "Choose an interface." }
        do {
            _ = try candidate.addresses()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("Configure Network Scan")
                .font(.title2.weight(.semibold))
                .padding(.top, 22)
                .padding(.bottom, 18)

            HStack(alignment: .top, spacing: 24) {
                interfaceSection
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                Divider().frame(height: 230)
                rangeSection
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .padding(.horizontal, 28)

            Spacer(minLength: 14)
            Divider()
            HStack {
                if let validationMessage {
                    Text(validationMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Scan") {
                    guard let candidate else { return }
                    onScan(candidate)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(validationMessage != nil)
            }
            .padding(14)
        }
        .frame(width: 760, height: 360)
        .onChange(of: selectedID) { _, _ in resetRange() }
    }

    private var interfaceSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("INTERFACE")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Picker("", selection: $selectedID) {
                ForEach(choices) { choice in
                    Text("\(choice.displayName) (\(choice.bsdName))").tag(choice.id)
                }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity)

            if let choice = selectedChoice {
                configDetail("Name", choice.displayName)
                configDetail("MAC", choice.macAddress)
                configDetail(
                    "IP / Mask",
                    choice.mask.map { "\(choice.ipv4Address)    \($0)" }
                        ?? choice.ipv4Address)
                configDetail("Gateway", choice.gateway)
            }
        }
    }

    private var rangeSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("SUBNET RANGE")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Reset", action: resetRange)
                    .buttonStyle(.link)
            }
            LabeledContent("From") {
                TextField("192.168.1.1", text: $fromAddress)
                    .font(.body.monospacedDigit())
                    .frame(width: 190)
            }
            LabeledContent("To") {
                TextField("192.168.1.254", text: $toAddress)
                    .font(.body.monospacedDigit())
                    .frame(width: 190)
            }
            if let candidate, let count = try? candidate.addresses().count {
                Text("\(count) addresses will be checked on \(candidate.interfaceName).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func configDetail(_ label: String, _ value: String?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary).frame(width: 78, alignment: .trailing)
            Text(value ?? "Not available")
                .font(.body.monospacedDigit())
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func resetRange() {
        guard let range = selectedChoice?.suggestedRange else { return }
        fromAddress = range.from
        toAddress = range.to
    }
}

// MARK: - Port scan configuration

private struct NetworkPortScanTarget: Identifiable {
    let address: String
    var id: String { address }
}

private struct NetworkPortScanConfigurationSheet: View {
    private enum Scope: String, CaseIterable {
        case common = "Common services"
        case range = "Port range"
    }

    let address: String
    let onStart: ([UInt16]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var scope = Scope.common
    @State private var firstPort = "1"
    @State private var lastPort = "1024"

    private var ports: [UInt16]? {
        if scope == .common { return NetworkScanViewModel.commonPorts }
        guard let first = UInt16(firstPort), let last = UInt16(lastPort),
            first > 0, first <= last,
            Int(last) - Int(first) + 1 <= 4096
        else { return nil }
        return Array(first...last)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Port Scan").font(.title2.weight(.semibold))
                Text(address).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }

            Picker("Scope", selection: $scope) {
                ForEach(Scope.allCases, id: \.self) { scope in
                    Text(scope.rawValue).tag(scope)
                }
            }
            .pickerStyle(.segmented)

            if scope == .range {
                HStack {
                    LabeledContent("From") {
                        TextField("1", text: $firstPort)
                            .font(.body.monospacedDigit()).frame(width: 72)
                    }
                    LabeledContent("To") {
                        TextField("1024", text: $lastPort)
                            .font(.body.monospacedDigit()).frame(width: 72)
                    }
                }
            } else {
                Text("Checks \(NetworkScanViewModel.commonPorts.count) common TCP service ports.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            if scope == .range, ports == nil {
                Text("Enter a valid range containing no more than 4096 ports.")
                    .font(.caption).foregroundStyle(.red)
            }

            Spacer()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Start Scan") {
                    guard let ports else { return }
                    onStart(ports)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(ports == nil)
            }
        }
        .padding(22)
        .frame(width: 430, height: 275)
    }
}
