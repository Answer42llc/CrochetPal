import SwiftUI

struct DebugLogView: View {
    @EnvironmentObject private var container: AppContainer

    var body: some View {
        NavigationStack {
            List(container.repository.recentLogs) { event in
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
        }
    }
}
