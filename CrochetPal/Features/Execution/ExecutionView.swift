import SwiftUI

struct ExecutionView: View {
    @EnvironmentObject private var container: AppContainer
    let projectID: UUID

    @State private var isShowingEditor = false

    private var record: ProjectRecord? {
        container.repository.records.first(where: { $0.project.id == projectID })
    }

    private var executionState: ProjectExecutionState {
        container.repository.executionState(for: projectID)
    }

    private var snapshot: ProjectSnapshot? {
        container.repository.snapshot(for: projectID)
    }

    private var currentRoundID: UUID? {
        guard let record else { return nil }
        return ExecutionEngine.currentRound(in: record.project, progress: record.progress)?.id
    }

    static func shouldShowRegenerateButton(
        sourceType: PatternSourceType,
        round: PatternRound?
    ) -> Bool {
        sourceType.supportsDeferredAtomization && round != nil
    }

    var body: some View {
        Group {
            if let record, let snapshot {
                let nextAction = ExecutionEngine.nextAction(in: record.project, progress: record.progress)
                let round = ExecutionEngine.currentRound(in: record.project, progress: record.progress)
                let isAwaitingNextRound = ExecutionEngine.isAwaitingNextRound(
                    in: record.project,
                    progress: record.progress
                )
                let shouldShowRegenerateButton = Self.shouldShowRegenerateButton(
                    sourceType: record.project.source.type,
                    round: round
                ) && !isAwaitingNextRound
                let primaryButtonTitle = isAwaitingNextRound ? "Enter Next Round" : "Continue"
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(snapshot.partName)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(snapshot.roundTitle)
                            .font(.largeTitle.bold())
                        Text(round?.summary ?? "This project is complete.")
                            .font(.body)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Current Action")
                            .font(.headline)
                        Text(snapshot.actionTitle)
                            .font(.system(size: 44, weight: .bold, design: .rounded))
                            .lineLimit(nil)
                            .minimumScaleFactor(0.5)
                            .fixedSize(horizontal: false, vertical: true)
                        if let actionHint = snapshot.actionHint, !actionHint.isEmpty {
                            Text(actionHint)
                                .font(.title3)
                        }
                        if let actionNote = snapshot.actionNote, !actionNote.isEmpty {
                            Text(actionNote)
                                .font(.body)
                                .foregroundStyle(.secondary)
                        }
                        if let statusMessage = snapshot.statusMessage, snapshot.executionState != .ready {
                            Text(statusMessage)
                                .font(.body)
                                .foregroundStyle(snapshot.executionState == .failed ? .red : .secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 20))

                    VStack(alignment: .leading, spacing: 10) {
                        if let actionSequenceProgress = snapshot.actionSequenceProgress,
                           let actionSequenceTotal = snapshot.actionSequenceTotal {
                            Label(
                                "Action progress: \(actionSequenceProgress)/\(actionSequenceTotal)",
                                systemImage: "list.number"
                            )
                        }
                        Label("Stitch progress: \(snapshot.stitchProgress)/\(snapshot.targetStitches ?? 0)", systemImage: "number")
                        if round?.atomizationWarning != nil {
                            Label(
                                "目标针数与实际展开不一致，已按指令展开",
                                systemImage: "exclamationmark.triangle.fill"
                            )
                            .font(.caption)
                            .foregroundStyle(.orange)
                        }
                        if let nextAction {
                            Label("Next: \(nextAction.executionDisplayTitle)", systemImage: "arrow.turn.down.right")
                        }
                    }
                    .font(.headline)

                    if shouldShowRegenerateButton, let round {
                        Button {
                            Task {
                                await container.repository.regenerateRound(
                                    projectID: projectID,
                                    partID: record.progress.cursor.partID,
                                    roundID: round.id
                                )
                            }
                        } label: {
                            Label("Regenerate", systemImage: "arrow.clockwise")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("regenerateCurrentRound")
                        .disabled(executionState.isBusy && executionState != .parsingNextRound)
                    }

                    Spacer()

                    HStack(spacing: 16) {
                        Button {
                            container.repository.undoExecution(projectID: projectID, source: .phoneButton)
                        } label: {
                            Label("Undo", systemImage: "arrow.uturn.backward.circle")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(
                            record.progress.history.isEmpty ||
                            (snapshot.executionState == .loading && !isAwaitingNextRound)
                        )

                        Button {
                            Task {
                                await container.repository.continueExecution(projectID: projectID, source: .phoneButton)
                            }
                        } label: {
                            Label(primaryButtonTitle, systemImage: "arrow.right.circle.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.teal)
                        .disabled(!snapshot.canAdvance)
                    }
                }
                .padding()
                .navigationTitle(record.project.title)
                .navigationBarTitleDisplayMode(.inline)
                .task(id: projectID) {
                    await container.repository.prepareExecution(projectID: projectID)
                }
                .onChange(of: currentRoundID) { _, _ in
                    Task {
                        await container.repository.onRoundDidAppear(projectID: projectID)
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            isShowingEditor = true
                        } label: {
                            Image(systemName: "slider.horizontal.3")
                        }
                        .disabled(round?.atomizationStatus != .ready || isAwaitingNextRound)
                    }
                }
                .sheet(isPresented: $isShowingEditor) {
                    if let round,
                       let partID = record.project.parts.first(where: { $0.id == record.progress.cursor.partID })?.id,
                       round.atomizationStatus == .ready {
                        RoundEditorView(projectID: projectID, partID: partID, round: round)
                            .environmentObject(container)
                    }
                }
            } else {
                ContentUnavailableView("Execution Missing", systemImage: "xmark.circle")
            }
        }
    }
}
