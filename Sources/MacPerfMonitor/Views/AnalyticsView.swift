// SPDX-License-Identifier: MIT

import MacPerfMonitorCore
import SwiftUI

/// Hosts Explorer, the optional process monitor, and imported traces. The
/// internal tab identity stays unchanged for existing navigation and Finder routes.
///
/// It also consumes a trace opened from Finder (routed through
/// `AppState.pendingTraceURL`) so a double-clicked file lands here.
struct AnalyticsView: View {
    @EnvironmentObject private var appState: AppState

    let explorer: DataExplorerModel
    @Binding var imported: ImportedTrace?
    @State private var legacy = false
    @State private var importError: String?
    @State private var importRequestID: UUID?

    var body: some View {
        Group {
            if let imported {
                TraceViewerView(trace: imported) { self.imported = nil }
                    .id(imported.id)
            } else if legacy {
                VStack(spacing: 0) {
                    HStack {
                        Button("Back to Explorer") { legacy = false }
                        Spacer()
                    }.padding(12)
                    Divider()
                    PerformanceMonitorView(onImport: { imported = $0 })
                }
            } else {
                DataExplorerView(
                    explorer: explorer, onImport: { imported = $0 }, onLegacy: { legacy = true })
            }
        }
        .onAppear { consumePendingTrace() }
        .onChange(of: appState.pendingTraceURL) { consumePendingTrace() }
        .alert(
            "Could not open trace",
            isPresented: Binding(
                get: { importError != nil }, set: { if !$0 { importError = nil } })
        ) {
            Button("OK", role: .cancel) { importError = nil }
        } message: {
            Text(importError ?? "")
        }
    }

    /// Decode and show a trace that was opened from Finder, if one is waiting.
    private func consumePendingTrace() {
        guard let url = appState.pendingTraceURL else { return }
        appState.pendingTraceURL = nil
        let requestID = UUID()
        importRequestID = requestID
        TraceFileLoader.load(url) { result in
            guard importRequestID == requestID else { return }
            importRequestID = nil
            switch result {
            case .success(let trace):
                imported = trace
            case .failure(let error):
                importError =
                    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}
