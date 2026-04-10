import SwiftUI

struct ProjectDetailView: View {
    @EnvironmentObject private var container: AppContainer
    let projectID: UUID

    var body: some View {
        Group {
            if let record = container.repository.records.first(where: { $0.project.id == projectID }) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(record.project.title)
                                .font(.largeTitle.bold())
                            Text(record.project.source.displayName)
                                .foregroundStyle(.secondary)
                            ProgressView(value: ExecutionEngine.progressFraction(for: record))
                                .tint(.teal)
                        }

                        if !record.project.materials.isEmpty {
                            infoCard(title: "Materials", values: record.project.materials)
                        }

                        VStack(alignment: .leading, spacing: 12) {
                            Text("Parts")
                                .font(.title3.bold())
                            ForEach(record.project.parts) { part in
                                Button {
                                    container.repository.setActiveProject(projectID)
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(part.name)
                                                .font(.headline)
                                            Text("\(part.rounds.count) rounds")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding()
                                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding()
                }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        NavigationLink("Execute") {
                            ExecutionView(projectID: projectID)
                        }
                        .accessibilityIdentifier("executeProject")
                    }
                }
            } else {
                ContentUnavailableView("Project Missing", systemImage: "exclamationmark.triangle")
            }
        }
        .navigationTitle("Project")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func infoCard(title: String, values: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.title3.bold())
            ForEach(values, id: \.self) { value in
                Text("• \(value)")
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }
}
