import SwiftUI

struct ProjectListView: View {
    @EnvironmentObject private var container: AppContainer
    @State private var isShowingImportSheet = false
    @State private var isShowingLogs = false

    var body: some View {
        List {
            if container.repository.records.isEmpty {
                ContentUnavailableView(
                    "No Project Yet",
                    systemImage: "figure.2.and.child.holdinghands",
                    description: Text("Import a web, text, or image pattern to start tracking stitches.")
                )
                .listRowBackground(Color.clear)
            } else {
                ForEach(container.repository.records) { record in
                    if record.importState.isReady {
                        NavigationLink {
                            ProjectDetailView(projectID: record.project.id)
                        } label: {
                            readyProjectRow(record)
                        }
                        .accessibilityIdentifier("projectLink-\(record.project.title)")
                    } else {
                        importStatusRow(record)
                    }
                }
            }
        }
        .navigationTitle("Projects")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    isShowingLogs = true
                } label: {
                    Image(systemName: "doc.text.magnifyingglass")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isShowingImportSheet = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                }
                .accessibilityIdentifier("addProject")
            }
        }
        .sheet(isPresented: $isShowingImportSheet) {
            ImportSheet { projectID in
                container.repository.setActiveProject(projectID)
            }
            .environmentObject(container)
        }
        .sheet(isPresented: $isShowingLogs) {
            DebugLogView()
                .environmentObject(container)
        }
    }

    private func readyProjectRow(_ record: ProjectRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(record.project.title)
                    .font(.headline)
                Spacer()
                Text(record.project.source.type.rawValue.capitalized)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.teal.opacity(0.15), in: Capsule())
            }

            ProgressView(value: ExecutionEngine.progressFraction(for: record))
                .tint(.teal)

            HStack {
                if let snapshot = record.project.id == container.repository.activeProjectID
                    ? container.repository.snapshot(for: record.project.id)
                    : nil {
                    Text("\(snapshot.partName) · \(snapshot.roundTitle)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(record.project.source.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    container.repository.setActiveProject(record.project.id)
                } label: {
                    Image(systemName: "play.circle.fill")
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("setActiveProject")
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("projectRow-\(record.project.title)")
    }

    private func importStatusRow(_ record: ProjectRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(record.project.title)
                        .font(.headline)
                    Text(record.project.source.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(record.project.source.type.rawValue.capitalized)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.orange.opacity(0.15), in: Capsule())
            }

            HStack(spacing: 10) {
                if record.importState.isInProgress {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(record.importState.message)
                        .font(.caption.weight(.semibold))
                    if let error = record.importState.errorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }

                Spacer()

                if record.importState.isFailed {
                    Button {
                        container.repository.retryImport(projectID: record.project.id)
                    } label: {
                        Label("Retry", systemImage: "arrow.clockwise")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityIdentifier("retryImport")
                }
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("importRow-\(record.project.id.uuidString)")
    }
}
