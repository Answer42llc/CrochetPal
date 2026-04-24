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
        if isAwaitingNextRound(in: project, progress: progress) {
            return nextRound(in: project, progress: progress)?.atomicActions.first
        }
        let moved = advance(progress, in: project, source: .sync, now: progress.lastUpdatedAt)
        return currentAction(in: project, progress: moved)
    }

    static func isAwaitingNextRound(in project: CrochetProject, progress: ExecutionProgress) -> Bool {
        guard progress.completedAt == nil,
              let round = currentRound(in: project, progress: progress),
              round.atomizationStatus == .ready else {
            return false
        }

        // A `.ready` round with zero expanded actions is ambiguous: it is either a
        // legitimate narrative-only round (e.g. "Begin flap — transition to rows"), or a
        // malformed atomization result that dropped all declared stitches. We distinguish
        // by `targetStitchCount`: if the pattern declared a stitch count we still expect
        // actions, so keep the user blocked for regeneration; if no count was declared
        // we trust the empty atomization and let the user advance to the next round.
        if round.atomicActions.isEmpty {
            guard (round.targetStitchCount ?? 0) == 0,
                  nextRoundCursor(in: project, progress: progress) != nil else {
                return false
            }
            return true
        }

        return progress.cursor.actionIndex == round.atomicActions.count &&
            nextRoundCursor(in: project, progress: progress) != nil
    }

    static func nextRoundReference(in project: CrochetProject, progress: ExecutionProgress) -> RoundReference? {
        guard let nextCursor = nextRoundCursor(in: project, progress: progress),
              let part = project.parts.first(where: { $0.id == nextCursor.partID }),
              part.rounds.indices.contains(nextCursor.roundIndex) else {
            return nil
        }

        let nextRound = part.rounds[nextCursor.roundIndex]
        return RoundReference(partID: part.id, roundID: nextRound.id)
    }

    static func snapshot(for record: ProjectRecord, executionState: ProjectExecutionState) -> ProjectSnapshot {
        let project = record.project
        let progress = record.progress
        let currentPart = currentPart(in: project, progress: progress) ?? project.parts.first
        let currentRound = currentRound(in: project, progress: progress)
        let currentAction = currentAction(in: project, progress: progress)
        let nextAction = nextAction(in: project, progress: progress)
        let actionSequence = currentActionSequence(in: currentRound, progress: progress)
        let stitchProgress = producedStitchesBeforeCursor(project: project, progress: progress)
        let isComplete = progress.completedAt != nil
        let isAwaitingNextRound = isAwaitingNextRound(in: project, progress: progress)

        return ProjectSnapshot(
            projectID: project.id,
            title: project.title,
            partName: currentPart?.name ?? "No Part",
            roundTitle: currentRound?.title ?? "Complete",
            actionTitle: snapshotActionTitle(
                currentAction: currentAction,
                round: currentRound,
                isAwaitingNextRound: isAwaitingNextRound,
                executionState: executionState,
                isComplete: isComplete
            ),
            actionHint: snapshotActionHint(
                currentAction: currentAction,
                round: currentRound,
                isAwaitingNextRound: isAwaitingNextRound,
                executionState: executionState,
                isComplete: isComplete
            ),
            actionNote: currentAction?.note,
            nextActionTitle: nextAction?.executionDisplayTitle,
            actionSequenceProgress: actionSequence?.progress,
            actionSequenceTotal: actionSequence?.total,
            stitchProgress: stitchProgress,
            targetStitches: currentRound?.targetStitchCount ?? currentRound?.resolvedStitchCount,
            executionState: isComplete ? .complete : executionState.snapshotState,
            statusMessage: isComplete ? "已完成" : executionState.statusMessage,
            canAdvance: !isComplete && (isAwaitingNextRound || (executionState.canAdvance && currentAction != nil)),
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

    private static func currentActionSequence(
        in round: PatternRound?,
        progress: ExecutionProgress
    ) -> (progress: Int, total: Int)? {
        guard let round,
              round.atomizationStatus == .ready,
              round.atomicActions.indices.contains(progress.cursor.actionIndex) else {
            return nil
        }

        let currentIndex = progress.cursor.actionIndex
        let currentAction = round.atomicActions[currentIndex]
        var lowerBound = currentIndex
        var upperBound = currentIndex

        while lowerBound > 0,
              round.atomicActions[lowerBound - 1].matchesExecutionDisplay(as: currentAction) {
            lowerBound -= 1
        }

        while upperBound + 1 < round.atomicActions.count,
              round.atomicActions[upperBound + 1].matchesExecutionDisplay(as: currentAction) {
            upperBound += 1
        }

        let total = upperBound - lowerBound + 1
        guard total > 1 else {
            return nil
        }

        return (currentIndex - lowerBound + 1, total)
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
        isAwaitingNextRound: Bool,
        executionState: ProjectExecutionState,
        isComplete: Bool
    ) -> String {
        if isComplete {
            return "Done"
        }
        if isAwaitingNextRound {
            return "Complete"
        }
        if let currentAction {
            return currentAction.executionDisplayTitle
        }
        switch executionState {
        case .bootstrapping, .parsingNextRound, .regeneratingCurrentRound:
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
        isAwaitingNextRound: Bool,
        executionState: ProjectExecutionState,
        isComplete: Bool
    ) -> String? {
        if isComplete {
            return "Project complete"
        }
        if isAwaitingNextRound {
            return "Tap Enter Next Round when you're ready."
        }
        if let currentAction {
            return currentAction.executionDisplayHint
        }
        switch executionState {
        case .bootstrapping, .parsingNextRound, .regeneratingCurrentRound:
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
        guard round.atomizationStatus == .ready else {
            return progress
        }

        var updated = progress
        updated.lastCommandSource = source
        updated.lastUpdatedAt = now

        if isAwaitingNextRound(in: project, progress: progress) {
            guard let nextCursor = nextRoundCursor(in: project, progress: progress) else {
                return progress
            }

            updated.history.append(progress.cursor)
            updated.cursor = nextCursor
            return updated
        }

        guard round.atomicActions.indices.contains(progress.cursor.actionIndex) else {
            return progress
        }

        updated.history.append(progress.cursor)
        updated.cursor.actionIndex += 1

        if updated.cursor.actionIndex >= round.atomicActions.count,
           nextRoundCursor(in: project, progress: progress) == nil {
            updated.completedAt = now
        }
        return updated
    }

    private static func nextRound(in project: CrochetProject, progress: ExecutionProgress) -> PatternRound? {
        guard let nextCursor = nextRoundCursor(in: project, progress: progress),
              let part = project.parts.first(where: { $0.id == nextCursor.partID }),
              part.rounds.indices.contains(nextCursor.roundIndex) else {
            return nil
        }

        return part.rounds[nextCursor.roundIndex]
    }

    private static func nextRoundCursor(in project: CrochetProject, progress: ExecutionProgress) -> ExecutionCursor? {
        guard let partIndex = project.parts.firstIndex(where: { $0.id == progress.cursor.partID }) else {
            return nil
        }

        let part = project.parts[partIndex]
        guard part.rounds.indices.contains(progress.cursor.roundIndex) else {
            return nil
        }

        if part.rounds.indices.contains(progress.cursor.roundIndex + 1) {
            return ExecutionCursor(
                partID: part.id,
                roundIndex: progress.cursor.roundIndex + 1,
                actionIndex: 0
            )
        }

        if project.parts.indices.contains(partIndex + 1),
           project.parts[partIndex + 1].rounds.isEmpty == false {
            return ExecutionCursor(
                partID: project.parts[partIndex + 1].id,
                roundIndex: 0,
                actionIndex: 0
            )
        }

        return nil
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
