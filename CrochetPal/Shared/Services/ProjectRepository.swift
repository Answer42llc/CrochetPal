import Combine
import Foundation

@MainActor
final class ProjectRepository: ObservableObject {
    @Published private(set) var records: [ProjectRecord]
    @Published private(set) var executionStates: [UUID: ProjectExecutionState]
    @Published var activeProjectID: UUID?
    @Published var recentLogs: [LogEvent]

    private let importer: PatternImporting
    private let storage: JSONFileStoring
    private let logger: ConsoleTraceLogger
    private let filename = "projects.json"
    private var watchSync: WatchSyncCoordinator?

    init(
        importer: PatternImporting,
        storage: JSONFileStoring,
        logger: ConsoleTraceLogger
    ) {
        self.importer = importer
        self.storage = storage
        self.records = []
        self.executionStates = [:]
        self.recentLogs = []
        self.logger = logger
        self.logger.updateSink { [weak self] event in
            guard let self else { return }
            DispatchQueue.main.async {
                self.recentLogs.insert(event, at: 0)
                self.recentLogs = Array(self.recentLogs.prefix(200))
            }
        }
        load()
    }

    func attachWatchSync(_ coordinator: WatchSyncCoordinator) {
        watchSync = coordinator
        coordinator.onCommandReceived = { [weak self] projectID, command, source in
            Task { @MainActor in
                guard let self else { return }
                switch command {
                case .forward:
                    await self.continueExecution(projectID: projectID, source: source)
                case .undo:
                    self.undoExecution(projectID: projectID, source: source)
                }
            }
        }
        coordinator.requestSnapshotProvider = { [weak self] in
            await MainActor.run {
                guard let self, let active = self.activeRecord else { return nil }
                return self.snapshot(for: active.project.id)
            }
        }
        pushActiveSnapshot()
    }

    var activeRecord: ProjectRecord? {
        let id = activeProjectID ?? records.first?.project.id
        return records.first(where: { $0.project.id == id })
    }

    func executionState(for projectID: UUID) -> ProjectExecutionState {
        executionStates[projectID] ?? .idle
    }

    func importWebPattern(from urlString: String) async throws -> ProjectRecord {
        let record = try await importer.importWebPattern(from: urlString)
        upsert(record)
        return record
    }

    func importTextPattern(from rawText: String) async throws -> ProjectRecord {
        let record = try await importer.importTextPattern(from: rawText)
        upsert(record)
        return record
    }

    func importImagePattern(data: Data, fileName: String) async throws -> ProjectRecord {
        let record = try await importer.importImagePattern(data: data, fileName: fileName)
        upsert(record)
        return record
    }

    func setActiveProject(_ projectID: UUID) {
        activeProjectID = projectID
        pushActiveSnapshot()
    }

    func prepareExecution(projectID: UUID) async {
        guard let record = record(for: projectID),
              record.project.source.type.supportsDeferredAtomization,
              record.progress.completedAt == nil else {
            return
        }

        if executionState(for: projectID).isBusy {
            return
        }

        guard let currentRound = ExecutionEngine.currentRound(in: record.project, progress: record.progress) else {
            setExecutionState(.idle, for: projectID)
            return
        }

        switch currentRound.atomizationStatus {
        case .ready:
            setExecutionState(.idle, for: projectID)
            return
        case .failed:
            setExecutionState(.failed(currentRound.atomizationError ?? "步骤解析失败"), for: projectID)
            return
        case .pending:
            break
        }

        let targets = pendingRoundTargets(for: record, limit: 1)
        guard !targets.isEmpty else {
            setExecutionState(.idle, for: projectID)
            return
        }

        _ = await atomizeTargets(
            targets,
            in: projectID,
            pendingState: .bootstrapping
        )
    }

    func continueExecution(projectID: UUID, source: ExecutionCommandSource) async {
        guard let initialRecord = record(for: projectID) else { return }
        let isAwaitingNextRound = ExecutionEngine.isAwaitingNextRound(
            in: initialRecord.project,
            progress: initialRecord.progress
        )
        let currentState = executionState(for: projectID)
        guard !currentState.isBusy || isAwaitingNextRound || currentState == .parsingNextRound else { return }

        let oldRoundIndex = initialRecord.progress.cursor.roundIndex
        let oldPartID = initialRecord.progress.cursor.partID

        apply(.forward, to: projectID, source: source)

        guard let updated = record(for: projectID),
              updated.project.source.type.supportsDeferredAtomization else {
            return
        }

        if updated.progress.cursor.roundIndex != oldRoundIndex ||
           updated.progress.cursor.partID != oldPartID {
            await handleRoundDidAppear(for: projectID)
        }
    }

    func regenerateRound(projectID: UUID, partID: UUID, roundID: UUID) async {
        let state = executionState(for: projectID)
        guard state == .idle || state == .parsingNextRound else { return }
        _ = await atomizeTargets(
            [RoundReference(partID: partID, roundID: roundID)],
            in: projectID,
            pendingState: .regeneratingCurrentRound
        )
    }

    func undoExecution(projectID: UUID, source: ExecutionCommandSource) {
        apply(.undo, to: projectID, source: source)
    }

    func update(round draftRound: PatternRound, in partID: UUID, projectID: UUID) {
        guard let projectIndex = records.firstIndex(where: { $0.project.id == projectID }),
              let partIndex = records[projectIndex].project.parts.firstIndex(where: { $0.id == partID }),
              let roundIndex = records[projectIndex].project.parts[partIndex].rounds.firstIndex(where: { $0.id == draftRound.id }) else {
            return
        }

        var updatedRound = draftRound
        updatedRound.atomizationStatus = .ready
        updatedRound.atomizationError = nil
        records[projectIndex].project.parts[partIndex].rounds[roundIndex] = updatedRound
        records[projectIndex].project.updatedAt = .now
        persist()
        pushActiveSnapshot()
    }

    func snapshot(for projectID: UUID) -> ProjectSnapshot? {
        guard let record = record(for: projectID) else { return nil }
        return ExecutionEngine.snapshot(for: record, executionState: executionState(for: projectID))
    }

    func clearRecentLogs() {
        recentLogs.removeAll()
    }

    private func apply(_ command: ExecutionCommand, to projectID: UUID, source: ExecutionCommandSource) {
        guard let index = records.firstIndex(where: { $0.project.id == projectID }) else { return }
        var record = records[index]
        record.progress = ExecutionEngine.apply(command, to: record.progress, in: record.project, source: source)
        record.project.updatedAt = .now
        records[index] = record
        persist()
        pushActiveSnapshot()
    }

    private func atomizeTargets(
        _ targets: [RoundReference],
        in projectID: UUID,
        pendingState: ProjectExecutionState
    ) async -> Bool {
        guard !targets.isEmpty, let record = record(for: projectID) else {
            return true
        }

        setExecutionState(pendingState, for: projectID)

        do {
            let updates = try await importer.atomizeRounds(in: record.project, targets: targets)
            applyAtomizedUpdates(updates, to: projectID)
            setExecutionState(.idle, for: projectID)
            startAutoParseOfNextRound(for: projectID)
            return true
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            markRoundsFailed(targets, in: projectID, message: message)
            if shouldPreserveRoundCompletionStateAfterFailure(
                for: targets,
                in: projectID,
                pendingState: pendingState
            ) {
                setExecutionState(.idle, for: projectID)
            } else {
                setExecutionState(.failed(message), for: projectID)
            }
            return false
        }
    }

    private func pendingRoundTargets(for record: ProjectRecord, limit: Int) -> [RoundReference] {
        flattenedRoundReferences(for: record.project, from: record.progress)
            .filter { reference in
                round(for: reference, in: record.project)?.atomizationStatus == .pending
            }
            .prefix(limit)
            .map { $0 }
    }

    func onRoundDidAppear(projectID: UUID) async {
        await handleRoundDidAppear(for: projectID)
    }

    private func handleRoundDidAppear(for projectID: UUID) async {
        guard let record = record(for: projectID),
              record.project.source.type.supportsDeferredAtomization,
              record.progress.completedAt == nil,
              let currentRound = ExecutionEngine.currentRound(in: record.project, progress: record.progress) else {
            return
        }

        switch currentRound.atomizationStatus {
        case .ready:
            startAutoParseOfNextRound(for: projectID)
        case .pending:
            guard !executionState(for: projectID).isBusy else { return }
            _ = await atomizeTargets(
                [RoundReference(partID: record.progress.cursor.partID, roundID: currentRound.id)],
                in: projectID,
                pendingState: .bootstrapping
            )
        case .failed:
            setExecutionState(.failed(currentRound.atomizationError ?? "步骤解析失败"), for: projectID)
        }
    }

    private func startAutoParseOfNextRound(for projectID: UUID) {
        guard let record = record(for: projectID),
              !executionState(for: projectID).isBusy,
              let currentRound = ExecutionEngine.currentRound(in: record.project, progress: record.progress),
              currentRound.atomizationStatus == .ready,
              let nextRef = ExecutionEngine.nextRoundReference(in: record.project, progress: record.progress),
              let nextRound = round(for: nextRef, in: record.project),
              nextRound.atomizationStatus == .pending else {
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await self.atomizeTargets(
                [nextRef],
                in: projectID,
                pendingState: .parsingNextRound
            )
        }
    }

    private func flattenedRoundReferences(for project: CrochetProject, from progress: ExecutionProgress) -> [RoundReference] {
        guard let startPartIndex = project.parts.firstIndex(where: { $0.id == progress.cursor.partID }) else {
            return []
        }

        var references: [RoundReference] = []
        for partIndex in startPartIndex..<project.parts.count {
            let part = project.parts[partIndex]
            let startRoundIndex = part.id == progress.cursor.partID ? progress.cursor.roundIndex : 0
            for roundIndex in startRoundIndex..<part.rounds.count {
                references.append(RoundReference(partID: part.id, roundID: part.rounds[roundIndex].id))
            }
        }
        return references
    }

    private func shouldPreserveRoundCompletionStateAfterFailure(
        for targets: [RoundReference],
        in projectID: UUID,
        pendingState: ProjectExecutionState
    ) -> Bool {
        guard pendingState == .parsingNextRound,
              let record = record(for: projectID),
              let currentRound = ExecutionEngine.currentRound(in: record.project, progress: record.progress) else {
            return false
        }

        return targets.allSatisfy { target in
            target.partID != record.progress.cursor.partID || target.roundID != currentRound.id
        }
    }

    private func applyAtomizedUpdates(_ updates: [AtomizedRoundUpdate], to projectID: UUID) {
        guard let projectIndex = records.firstIndex(where: { $0.project.id == projectID }) else { return }

        for update in updates {
            guard let partIndex = records[projectIndex].project.parts.firstIndex(where: { $0.id == update.reference.partID }),
                  let roundIndex = records[projectIndex].project.parts[partIndex].rounds.firstIndex(where: { $0.id == update.reference.roundID }) else {
                continue
            }

            records[projectIndex].project.parts[partIndex].rounds[roundIndex].atomicActions = update.atomicActions
            records[projectIndex].project.parts[partIndex].rounds[roundIndex].targetStitchCount = update.resolvedTargetStitchCount
            records[projectIndex].project.parts[partIndex].rounds[roundIndex].atomizationStatus = .ready
            records[projectIndex].project.parts[partIndex].rounds[roundIndex].atomizationError = nil
            records[projectIndex].project.parts[partIndex].rounds[roundIndex].atomizationWarning = update.warning
        }

        records[projectIndex].project.updatedAt = .now
        persist()
        pushActiveSnapshot()
    }

    private func markRoundsFailed(_ targets: [RoundReference], in projectID: UUID, message: String) {
        guard let projectIndex = records.firstIndex(where: { $0.project.id == projectID }) else { return }

        for target in targets {
            guard let partIndex = records[projectIndex].project.parts.firstIndex(where: { $0.id == target.partID }),
                  let roundIndex = records[projectIndex].project.parts[partIndex].rounds.firstIndex(where: { $0.id == target.roundID }) else {
                continue
            }

            records[projectIndex].project.parts[partIndex].rounds[roundIndex].atomizationStatus = .failed
            records[projectIndex].project.parts[partIndex].rounds[roundIndex].atomizationError = message
            records[projectIndex].project.parts[partIndex].rounds[roundIndex].atomicActions = []
        }

        records[projectIndex].project.updatedAt = .now
        persist()
        pushActiveSnapshot()
    }

    private func setExecutionState(_ state: ProjectExecutionState, for projectID: UUID) {
        executionStates[projectID] = state
        pushActiveSnapshot()
    }

    private func round(for reference: RoundReference, in project: CrochetProject) -> PatternRound? {
        project.parts
            .first(where: { $0.id == reference.partID })?
            .rounds
            .first(where: { $0.id == reference.roundID })
    }

    private func record(for projectID: UUID) -> ProjectRecord? {
        records.first(where: { $0.project.id == projectID })
    }

    private func upsert(_ record: ProjectRecord) {
        if let existingIndex = records.firstIndex(where: { $0.project.id == record.project.id }) {
            records[existingIndex] = record
        } else {
            records.insert(record, at: 0)
        }
        executionStates[record.project.id] = .idle
        activeProjectID = record.project.id
        persist()
        pushActiveSnapshot()
    }

    private func load() {
        records = (try? storage.load([ProjectRecord].self, from: filename)) ?? []
        activeProjectID = records.first?.project.id
        executionStates = Dictionary(uniqueKeysWithValues: records.map { ($0.project.id, .idle) })
    }

    private func persist() {
        try? storage.save(records, to: filename)
    }

    private func pushActiveSnapshot() {
        guard let projectID = activeProjectID, let snapshot = snapshot(for: projectID) else { return }
        Task {
            await watchSync?.push(snapshot: snapshot)
        }
    }
}
