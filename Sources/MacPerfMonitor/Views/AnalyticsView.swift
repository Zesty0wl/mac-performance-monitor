// SPDX-License-Identifier: MIT

import MacPerfMonitorCore
import SwiftUI

/// The Analytics tab host. It shows the live Performance Monitor by default and
/// swaps to the read-only `TraceViewerView` while an imported `.mpmtrace` file is
/// open, so the export/import feature stays entirely inside this tab. Closing the
/// trace returns to the live view.
///
/// It also consumes a trace opened from Finder (routed through
/// `AppState.pendingTraceURL`) so a double-clicked file lands here.
struct AnalyticsView: View {
    @EnvironmentObject private var appState: AppState

    @Binding var imported: ImportedTrace?
    @State private var importError: String?
    @State private var importRequestID: UUID?

    var body: some View {
        Group {
            if let imported {
                TraceViewerView(trace: imported) { self.imported = nil }
                    .id(imported.id)
            } else {
                PerformanceMonitorView(onImport: { imported = $0 })
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
