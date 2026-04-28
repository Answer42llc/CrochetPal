import SwiftUI

struct ExecutionView: View {
    @EnvironmentObject private var container: AppContainer
    let projectID: UUID

    @State private var isShowingEditor = false
    @State private var originalPatternPreview: OriginalPatternPreview?
    @State private var continueHapticTrigger = 0
    @State private var undoHapticTrigger = 0

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

    private var isRegenerateDisabled: Bool {
        switch executionState {
        case .idle, .parsingNextRound, .failed:
            return false
        case .bootstrapping, .regeneratingCurrentRound:
            return true
        }
    }

    static func shouldShowRegenerateButton(
        sourceType: PatternSourceType,
        round: PatternRound?
    ) -> Bool {
        sourceType.supportsDeferredAtomization && round != nil
    }

    private func hasOpenableOriginal(for source: PatternSource) -> Bool {
        switch source.type {
        case .web:
            guard let urlString = source.sourceURL,
                  let url = URL(string: urlString),
                  let scheme = url.scheme?.lowercased() else { return false }
            return scheme == "http" || scheme == "https"
        case .image, .pdf:
            guard let path = source.localFilePath else { return false }
            return container.sourceFileStore.resolveURL(forRelativePath: path) != nil
        case .text:
            return false
        }
    }

    private func openOriginalPattern(for source: PatternSource) {
        switch source.type {
        case .web:
            guard let urlString = source.sourceURL,
                  let url = URL(string: urlString),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else { return }
            originalPatternPreview = .web(url)
        case .image, .pdf:
            guard let path = source.localFilePath,
                  let url = container.sourceFileStore.resolveURL(forRelativePath: path) else { return }
            originalPatternPreview = .file(url)
        case .text:
            break
        }
    }

    var body: some View {
        Group {
            if let record, let snapshot {
                let nextAction = ExecutionEngine.nextAction(in: record.project, progress: record.progress)
                let round = ExecutionEngine.currentRound(in: record.project, progress: record.progress)
                let currentAction = ExecutionEngine.currentAction(in: record.project, progress: record.progress)
                let isAwaitingNextRound = ExecutionEngine.isAwaitingNextRound(
                    in: record.project,
                    progress: record.progress
                )
                let shouldShowRegenerateButton = Self.shouldShowRegenerateButton(
                    sourceType: record.project.source.type,
                    round: round
                )
                let primaryButtonTitle = isAwaitingNextRound ? "Enter Next Round" : "Continue"
                VStack(spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(snapshot.partName)
                                    .font(.title3.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Text(snapshot.roundTitle)
                                    .font(.largeTitle.bold())
                                Text(round?.summary ?? "This project is complete.")
                                    .font(.body)
                                if let rawInstruction = round?.rawInstruction, !rawInstruction.isEmpty {
                                    HighlightedInstructionText(
                                        rawInstruction: rawInstruction,
                                        actions: round?.atomicActions ?? [],
                                        currentActionID: currentAction?.id
                                    )
                                }
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
                                if let round,
                                   let warning = round.atomizationWarning,
                                   warning.split(separator: ";").contains("atomization_target_stitch_count_mismatch") {
                                    let actualStitches = round.atomicActions.reduce(0) { $0 + $1.producedStitches }
                                    let targetText = round.targetStitchCount.map(String.init) ?? "未知"
                                    Label(
                                        "目标针数与实际展开不一致（目标 \(targetText)，实际 \(actualStitches)），已按指令展开",
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

                        }
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    HStack(spacing: 16) {
                        Button {
                            undoHapticTrigger &+= 1
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
                            continueHapticTrigger &+= 1
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
                    .padding(.horizontal)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
                    .background(.bar)
                    .sensoryFeedback(.impact(weight: .medium), trigger: continueHapticTrigger)
                    .sensoryFeedback(.impact(weight: .light), trigger: undoHapticTrigger)
                }
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
                            openOriginalPattern(for: record.project.source)
                        } label: {
                            Image(systemName: "doc.text.magnifyingglass")
                        }
                        .accessibilityIdentifier("openOriginalPattern")
                        .accessibilityLabel("Open Original Pattern")
                        .disabled(!hasOpenableOriginal(for: record.project.source))
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button {
                                isShowingEditor = true
                            } label: {
                                Label("Edit Round", systemImage: "slider.horizontal.3")
                            }
                            .disabled(round?.atomizationStatus != .ready || isAwaitingNextRound)

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
                                }
                                .accessibilityIdentifier("regenerateCurrentRound")
                                .disabled(isRegenerateDisabled)
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .accessibilityIdentifier("executionActionsMenu")
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
                .sheet(item: $originalPatternPreview) { preview in
                    switch preview {
                    case .file(let url):
                        SourceFilePreviewSheet(url: url)
                    case .web(let url):
                        WebPagePreviewSheet(url: url)
                            .ignoresSafeArea()
                    }
                }
            } else {
                ContentUnavailableView("Execution Missing", systemImage: "xmark.circle")
            }
        }
    }
}

private enum OriginalPatternPreview: Identifiable {
    case file(URL)
    case web(URL)

    var id: String {
        switch self {
        case .file(let url): return "file:\(url.absoluteString)"
        case .web(let url): return "web:\(url.absoluteString)"
        }
    }
}
