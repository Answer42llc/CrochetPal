import SwiftUI

struct DebugLogView: View {
    @EnvironmentObject private var container: AppContainer

    private var recentLogs: [LogEvent] {
        container.repository.recentLogs
    }

    var body: some View {
        NavigationStack {
            List(recentLogs) { event in
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(event.stage) · \(event.decision)")
                        .font(.headline)
                    Text(event.reason)
                        .font(.subheadline)
                    Text(event.metadata.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .padding(.vertical, 4)
            }
            .navigationTitle("Trace Logs")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Clear", role: .destructive) {
                        container.repository.clearRecentLogs()
                    }
                    .disabled(recentLogs.isEmpty)
                    .accessibilityIdentifier("clearTraceLogs")
                }
            }
        }
    }
}
