import Foundation

enum ExecutionEngine {
    static func apply(
        _ command: ExecutionCommand,
        to progress: ExecutionProgress,
        in project: CrochetProject,
        source: ExecutionCommandSource,
        now: Date = .now
    ) -> ExecutionProgress {
        switch command {
        case .forward:
            return advance(progress, in: project, source: source, now: now)
        case .undo:
            return undo(progress, source: source, now: now)
        }
    }

    static func currentPart(in project: CrochetProject, progress: ExecutionProgress) -> PatternPart? {
        project.parts.first(where: { $0.id == progress.cursor.partID })
    }

    static func currentRound(in project: CrochetProject, progress: ExecutionProgress) -> PatternRound? {
        guard let part = currentPart(in: project, progress: progress),
              part.rounds.indices.contains(progress.cursor.roundIndex) else {
            return nil
        }
        return part.rounds[progress.cursor.roundIndex]
    }

    static func currentAction(in project: CrochetProject, progress: ExecutionProgress) -> AtomicAction? {
        guard let round = currentRound(in: project, progress: progress),
              round.atomizationStatus == .ready,
              round.atomicActions.indices.contains(progress.cursor.actionIndex) else {
            return nil
        }
        return round.atomicActions[progress.cursor.actionIndex]
    }

    static func nextAction(in project: CrochetProject, progress: ExecutionProgress) -> AtomicAction? {
        let moved = advance(progress, in: project, source: .sync, now: progress.lastUpdatedAt)
        return currentAction(in: project, progress: moved)
    }

    static func nextRoundReference(in project: CrochetProject, progress: ExecutionProgress) -> RoundReference? {
        guard let partIndex = project.parts.firstIndex(where: { $0.id == progress.cursor.partID }) else {
            return nil
        }
        let part = project.parts[partIndex]
        guard part.rounds.indices.contains(progress.cursor.roundIndex) else {
            return nil
        }

        if part.rounds.indices.contains(progress.cursor.roundIndex + 1) {
            let round = part.rounds[progress.cursor.roundIndex + 1]
            return RoundReference(partID: part.id, roundID: round.id)
        }

        if project.parts.indices.contains(partIndex + 1),
           let nextRound = project.parts[partIndex + 1].rounds.first {
            return RoundReference(partID: project.parts[partIndex + 1].id, roundID: nextRound.id)
        }

        return nil
    }

    static func snapshot(for record: ProjectRecord, executionState: ProjectExecutionState) -> ProjectSnapshot {
        let project = record.project
        let progress = record.progress
        let currentPart = currentPart(in: project, progress: progress) ?? project.parts.first
        let currentRound = currentRound(in: project, progress: progress)
        let currentAction = currentAction(in: project, progress: progress)
        let nextAction = nextAction(in: project, progress: progress)
        let stitchProgress = producedStitchesBeforeCursor(project: project, progress: progress)
        let isComplete = progress.completedAt != nil

        return ProjectSnapshot(
            projectID: project.id,
            title: project.title,
            partName: currentPart?.name ?? "No Part",
            roundTitle: currentRound?.title ?? "Complete",
            actionTitle: snapshotActionTitle(
                currentAction: currentAction,
                round: currentRound,
                executionState: executionState,
                isComplete: isComplete
            ),
            actionHint: snapshotActionHint(
                currentAction: currentAction,
                round: currentRound,
                executionState: executionState,
                isComplete: isComplete
            ),
            actionNote: currentAction?.note,
            nextActionTitle: nextAction?.type.title,
            stitchProgress: stitchProgress,
            targetStitches: currentRound?.targetStitchCount,
            executionState: isComplete ? .complete : executionState.snapshotState,
            statusMessage: isComplete ? "已完成" : executionState.statusMessage,
            canAdvance: !isComplete && executionState.canAdvance && currentAction != nil,
            isComplete: isComplete,
            updatedAt: progress.lastUpdatedAt
        )
    }

    static func producedStitchesBeforeCursor(project: CrochetProject, progress: ExecutionProgress) -> Int {
        guard let round = currentRound(in: project, progress: progress),
              round.atomizationStatus == .ready else {
            return 0
        }
        return round.atomicActions
            .prefix(progress.cursor.actionIndex)
            .reduce(0) { $0 + $1.producedStitches }
    }

    static func progressFraction(for record: ProjectRecord) -> Double {
        if record.project.hasPendingRounds {
            return coarseRoundProgress(for: record)
        }

        let total = max(record.project.totalAtomicActionCount, 1)
        let completed = completedActionCount(for: record)
        return Double(completed) / Double(total)
    }

    static func completedActionCount(for record: ProjectRecord) -> Int {
        var count = 0
        for part in record.project.parts {
            if part.id == record.progress.cursor.partID {
                for index in 0..<record.progress.cursor.roundIndex {
                    count += part.rounds[index].atomicActions.count
                }
                count += record.progress.cursor.actionIndex
                break
            } else {
                count += part.rounds.reduce(0) { $0 + $1.atomicActions.count }
            }
        }
        return min(count, record.project.totalAtomicActionCount)
    }

    private static func coarseRoundProgress(for record: ProjectRecord) -> Double {
        let totalRounds = max(record.project.totalRoundCount, 1)
        let completedRounds = completedRoundCount(for: record.project, progress: record.progress)
        let currentFraction = currentRoundFraction(for: record.project, progress: record.progress)
        return min(Double(completedRounds) + currentFraction, Double(totalRounds)) / Double(totalRounds)
    }

    private static func completedRoundCount(for project: CrochetProject, progress: ExecutionProgress) -> Int {
        var count = 0
        for part in project.parts {
            if part.id == progress.cursor.partID {
                count += progress.cursor.roundIndex
                break
            } else {
                count += part.rounds.count
            }
        }
        return count
    }

    private static func currentRoundFraction(for project: CrochetProject, progress: ExecutionProgress) -> Double {
        guard let round = currentRound(in: project, progress: progress),
              round.atomizationStatus == .ready,
              !round.atomicActions.isEmpty else {
            return 0
        }
        return Double(progress.cursor.actionIndex) / Double(round.atomicActions.count)
    }

    private static func snapshotActionTitle(
        currentAction: AtomicAction?,
        round: PatternRound?,
        executionState: ProjectExecutionState,
        isComplete: Bool
    ) -> String {
        if isComplete {
            return "Done"
        }
        if let currentAction {
            return currentAction.type.title
        }
        switch executionState {
        case .bootstrapping, .parsingNextRound:
            return "Loading"
        case .failed:
            return "Blocked"
        case .idle:
            return round?.atomizationStatus == .failed ? "Blocked" : "Ready"
        }
    }

    private static func snapshotActionHint(
        currentAction: AtomicAction?,
        round: PatternRound?,
        executionState: ProjectExecutionState,
        isComplete: Bool
    ) -> String {
        if isComplete {
            return "Project complete"
        }
        if let currentAction {
            return currentAction.instruction
        }
        switch executionState {
        case .bootstrapping, .parsingNextRound:
            return executionState.statusMessage ?? "正在解析步骤"
        case let .failed(message):
            return message
        case .idle:
            if round?.atomizationStatus == .failed {
                return round?.atomizationError ?? "步骤解析失败"
            }
            return "等待步骤解析"
        }
    }

    private static func advance(
        _ progress: ExecutionProgress,
        in project: CrochetProject,
        source: ExecutionCommandSource,
        now: Date
    ) -> ExecutionProgress {
        guard let partIndex = project.parts.firstIndex(where: { $0.id == progress.cursor.partID }) else {
            return progress
        }
        let part = project.parts[partIndex]
        guard part.rounds.indices.contains(progress.cursor.roundIndex) else {
            return progress
        }

        let round = part.rounds[progress.cursor.roundIndex]
        guard round.atomizationStatus == .ready,
              round.atomicActions.indices.contains(progress.cursor.actionIndex) else {
            return progress
        }

        var updated = progress
        updated.history.append(progress.cursor)
        updated.cursor.actionIndex += 1
        updated.lastCommandSource = source
        updated.lastUpdatedAt = now

        if updated.cursor.actionIndex >= round.atomicActions.count {
            if part.rounds.indices.contains(progress.cursor.roundIndex + 1) {
                updated.cursor.roundIndex += 1
                updated.cursor.actionIndex = 0
            } else if project.parts.indices.contains(partIndex + 1) {
                updated.cursor.partID = project.parts[partIndex + 1].id
                updated.cursor.roundIndex = 0
                updated.cursor.actionIndex = 0
            } else {
                updated.completedAt = now
            }
        }
        return updated
    }

    private static func undo(_ progress: ExecutionProgress, source: ExecutionCommandSource, now: Date) -> ExecutionProgress {
        guard let previous = progress.history.last else { return progress }
        var updated = progress
        updated.cursor = previous
        updated.history.removeLast()
        updated.lastCommandSource = source
        updated.lastUpdatedAt = now
        updated.completedAt = nil
        return updated
    }
}
