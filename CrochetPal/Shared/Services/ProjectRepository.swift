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
    private let sourceFileStore: SourceFileStoring?
    private let backgroundTaskRunner: BackgroundTaskRunning
    private let importNotificationScheduler: ImportNotificationScheduling
    private let filename = "projects.json"
    private var watchSync: WatchSyncCoordinator?
    private var runningImportIDs: Set<UUID> = []
    /// Per-project monotonic counter. Each `setExecutionState` increments it; long-running
    /// tasks capture the token they produced so their terminal state writes can be skipped
    /// when a newer operation has already taken over the state (e.g. user-initiated
    /// regenerate overtaking a background next-round prefetch).
    private var executionStateTokens: [UUID: Int] = [:]

    init(
        importer: PatternImporting,
        storage: JSONFileStoring,
        logger: ConsoleTraceLogger,
        sourceFileStore: SourceFileStoring? = nil,
        backgroundTaskRunner: BackgroundTaskRunning? = nil,
        importNotificationScheduler: ImportNotificationScheduling? = nil
    ) {
        self.importer = importer
        self.storage = storage
        self.sourceFileStore = sourceFileStore
        self.backgroundTaskRunner = backgroundTaskRunner ?? ApplicationBackgroundTaskRunner()
        self.importNotificationScheduler = importNotificationScheduler ?? NoopImportNotificationScheduler()
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
        if let activeProjectID,
           let record = records.first(where: { $0.project.id == activeProjectID }),
           record.importState.isReady {
            return record
        }
        return records.first(where: { $0.importState.isReady })
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

    func importPDFPattern(data: Data, fileName: String) async throws -> ProjectRecord {
        let record = try await importer.importPDFPattern(data: data, fileName: fileName)
        upsert(record)
        return record
    }

    @discardableResult
    func startWebImport(from urlString: String) throws -> UUID {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard URL(string: trimmed) != nil else {
            throw PatternImportFailure.invalidURL
        }
        return startImport(request: .web(urlString: trimmed))
    }

    @discardableResult
    func startTextImport(from rawText: String) throws -> UUID {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw PatternImportFailure.emptyExtraction
        }
        let data = Data(trimmed.utf8)
        let path = try saveImportSource(data: data, fileName: "pasted-pattern.txt")
        return startImport(request: .text(localFilePath: path))
    }

    @discardableResult
    func startImageImport(data: Data, fileName: String) throws -> UUID {
        guard !data.isEmpty else {
            throw PatternImportFailure.invalidResponse("empty_image_data")
        }
        let path = try saveImportSource(data: data, fileName: fileName)
        return startImport(request: .image(localFilePath: path, fileName: fileName, fileSizeBytes: data.count))
    }

    @discardableResult
    func startPDFImport(data: Data, fileName: String) throws -> UUID {
        guard !data.isEmpty else {
            throw PatternImportFailure.invalidResponse("empty_pdf_data")
        }
        let path = try saveImportSource(data: data, fileName: fileName)
        return startImport(request: .pdf(localFilePath: path, fileName: fileName, fileSizeBytes: data.count))
    }

    func retryImport(projectID: UUID) {
        guard let index = records.firstIndex(where: { $0.project.id == projectID }),
              let request = records[index].importRequest,
              records[index].importState.isFailed else {
            return
        }

        var state = PatternImportState.queued(
            retryCount: records[index].importState.retryCount + 1
        )
        state.move(to: .queued)
        records[index].importState = state
        records[index].importRequest = request
        records[index].project.updatedAt = .now
        persist()
        prepareImportCompletionNotifications()
        startImportTask(projectID: projectID)
    }

    func setActiveProject(_ projectID: UUID) {
        guard records.first(where: { $0.project.id == projectID })?.importState.isReady == true else {
            return
        }
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
            startAutoParseOfNextRound(for: projectID)
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
        switch state {
        case .idle, .parsingNextRound, .failed:
            break
        default:
            return
        }
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

    private func startImport(request: PatternImportRequest) -> UUID {
        let now = Date()
        let project = CrochetProject(
            title: request.placeholderTitle,
            source: PatternSource(
                type: request.sourceType,
                displayName: request.placeholderDisplayName,
                sourceURL: request.sourceURL,
                fileName: request.fileName,
                fileSizeBytes: request.fileSizeBytes,
                importedAt: now,
                localFilePath: request.localFilePath
            ),
            materials: [],
            confidence: 0,
            abbreviations: [],
            parts: [],
            activePartID: nil,
            createdAt: now,
            updatedAt: now
        )
        let record = ProjectRecord(
            project: project,
            progress: .initial(for: project),
            importState: .queued(now: now),
            importRequest: request
        )

        records.insert(record, at: 0)
        executionStates[project.id] = .idle
        persist()
        prepareImportCompletionNotifications()
        startImportTask(projectID: project.id)
        return project.id
    }

    private func startImportTask(projectID: UUID) {
        guard !runningImportIDs.contains(projectID) else { return }
        runningImportIDs.insert(projectID)

        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.backgroundTaskRunner.run(named: "CrochetPal Pattern Import") { [weak self] in
                await self?.performImport(projectID: projectID)
            }
            self.runningImportIDs.remove(projectID)
        }
    }

    private func performImport(projectID: UUID) async {
        guard let index = records.firstIndex(where: { $0.project.id == projectID }),
              let request = records[index].importRequest else {
            return
        }

        updateImportPhase(.queued, for: projectID)
        let progress: PatternImportProgressReporter = { [weak self] phase in
            await MainActor.run {
                self?.updateImportPhase(phase, for: projectID)
            }
        }

        do {
            let imported: ProjectRecord
            switch request.sourceType {
            case .web:
                guard let urlString = request.urlString else {
                    throw PatternImportFailure.invalidURL
                }
                imported = try await importer.importWebPattern(from: urlString, progress: progress)
            case .text:
                guard let localFilePath = request.localFilePath else {
                    throw PatternImportFailure.invalidResponse("missing_text_import_source")
                }
                let data = try loadImportSource(relativePath: localFilePath)
                guard let text = String(data: data, encoding: .utf8) else {
                    throw PatternImportFailure.invalidResponse("invalid_text_source_encoding")
                }
                imported = try await importer.importTextPattern(from: text, progress: progress)
            case .image:
                guard let localFilePath = request.localFilePath,
                      let fileName = request.fileName else {
                    throw PatternImportFailure.invalidResponse("missing_image_import_source")
                }
                let data = try loadImportSource(relativePath: localFilePath)
                imported = try await importer.importImagePattern(data: data, fileName: fileName, progress: progress)
            case .pdf:
                guard let localFilePath = request.localFilePath,
                      let fileName = request.fileName else {
                    throw PatternImportFailure.invalidResponse("missing_pdf_import_source")
                }
                let data = try loadImportSource(relativePath: localFilePath)
                imported = try await importer.importPDFPattern(data: data, fileName: fileName, progress: progress)
            }
            completeImport(imported, replacing: projectID)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            markImportFailed(projectID: projectID, message: message)
        }
    }

    private func completeImport(_ imported: ProjectRecord, replacing projectID: UUID) {
        guard let index = records.firstIndex(where: { $0.project.id == projectID }) else { return }

        var completed = imported
        let originalCreatedAt = records[index].project.createdAt
        completed.project.id = projectID
        completed.project.createdAt = originalCreatedAt
        completed.project.updatedAt = .now
        completed.progress.projectID = projectID
        completed.importState = .ready()
        completed.importRequest = nil
        records[index] = completed
        setExecutionState(.idle, for: projectID)
        activeProjectID = projectID
        persist()
        pushActiveSnapshot()
        notifyImportCompleted(projectID: projectID, projectTitle: completed.project.title)
        autoParseFirstRound(for: projectID)
    }

    private func prepareImportCompletionNotifications() {
        Task { @MainActor [importNotificationScheduler] in
            await importNotificationScheduler.prepareForImportCompletionNotifications()
        }
    }

    private func notifyImportCompleted(projectID: UUID, projectTitle: String) {
        Task { @MainActor [importNotificationScheduler] in
            await importNotificationScheduler.notifyImportCompleted(
                projectID: projectID,
                projectTitle: projectTitle
            )
        }
    }

    private func updateImportPhase(_ phase: PatternImportPhase, for projectID: UUID) {
        guard let index = records.firstIndex(where: { $0.project.id == projectID }),
              records[index].importState.phase != .failed,
              records[index].importState.phase != .ready else {
            return
        }

        records[index].importState.move(to: phase)
        records[index].project.updatedAt = .now
        persist()
    }

    private func markImportFailed(projectID: UUID, message: String) {
        guard let index = records.firstIndex(where: { $0.project.id == projectID }) else { return }

        records[index].importState.fail(message: message)
        records[index].project.updatedAt = .now
        persist()
    }

    private func saveImportSource(data: Data, fileName: String) throws -> String {
        guard let sourceFileStore else {
            throw PatternImportFailure.invalidResponse("missing_source_file_store")
        }
        return try sourceFileStore.saveSourceFile(data: data, fileName: fileName)
    }

    private func loadImportSource(relativePath: String) throws -> Data {
        guard let sourceFileStore,
              let url = sourceFileStore.resolveURL(forRelativePath: relativePath) else {
            throw PatternImportFailure.invalidResponse("missing_import_source_file")
        }
        return try Data(contentsOf: url)
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
        pendingState: ProjectExecutionState,
        prefetchNext: Bool = true
    ) async -> Bool {
        guard !targets.isEmpty, let record = record(for: projectID) else {
            return true
        }

        let token = setExecutionState(pendingState, for: projectID)

        do {
            let updates = try await importer.atomizeRounds(in: record.project, targets: targets)
            applyAtomizedUpdates(updates, to: projectID)
            setExecutionStateIfCurrent(.idle, for: projectID, expectedToken: token)
            if prefetchNext {
                startAutoParseOfNextRound(for: projectID)
            }
            return true
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            markRoundsFailed(targets, in: projectID, message: message)
            if shouldPreserveRoundCompletionStateAfterFailure(
                for: targets,
                in: projectID,
                pendingState: pendingState
            ) {
                setExecutionStateIfCurrent(.idle, for: projectID, expectedToken: token)
            } else {
                setExecutionStateIfCurrent(.failed(message), for: projectID, expectedToken: token)
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
            // Only backfill the pattern-declared target when it was not parsed from the outline stage.
            // NEVER overwrite a non-nil target with the atomization's produced count, otherwise an
            // LLM that expanded the round incorrectly (e.g., dropping all stitches into note nodes)
            // would silently erase the "(12)" the user saw in the raw pattern text.
            if records[projectIndex].project.parts[partIndex].rounds[roundIndex].targetStitchCount == nil {
                records[projectIndex].project.parts[partIndex].rounds[roundIndex].targetStitchCount = update.producedStitchCount
            }
            records[projectIndex].project.parts[partIndex].rounds[roundIndex].atomizationStatus = .ready
            records[projectIndex].project.parts[partIndex].rounds[roundIndex].atomizationError = nil
            records[projectIndex].project.parts[partIndex].rounds[roundIndex].atomizationWarning = update.warning
        }

        propagateAtomizationToMatchingRounds(updates, in: projectIndex)

        records[projectIndex].project.updatedAt = .now
        persist()
        pushActiveSnapshot()
    }

    /// Propagates atomization results to pending rounds that share both the same
    /// macroRepeatGroupID and macroRepeatSourceIndex as newly atomized rounds. Only
    /// expanded rounds (non-nil group + index, set by macro-repeat or range expansion)
    /// are eligible — regular rounds are never propagated. Matching by groupID keeps
    /// independent expansion groups isolated even when they share a sourceIndex value.
    private func propagateAtomizationToMatchingRounds(_ updates: [AtomizedRoundUpdate], in projectIndex: Int) {
        for update in updates {
            guard let partIndex = records[projectIndex].project.parts.firstIndex(where: { $0.id == update.reference.partID }),
                  let roundIndex = records[projectIndex].project.parts[partIndex].rounds.firstIndex(where: { $0.id == update.reference.roundID }) else {
                continue
            }

            let atomizedRound = records[projectIndex].project.parts[partIndex].rounds[roundIndex]
            guard let sourceIndex = atomizedRound.macroRepeatSourceIndex,
                  let groupID = atomizedRound.macroRepeatGroupID else {
                continue
            }

            for pIdx in records[projectIndex].project.parts.indices {
                for rIdx in records[projectIndex].project.parts[pIdx].rounds.indices {
                    let candidate = records[projectIndex].project.parts[pIdx].rounds[rIdx]
                    guard candidate.atomizationStatus == .pending,
                          candidate.macroRepeatGroupID == groupID,
                          candidate.macroRepeatSourceIndex == sourceIndex else {
                        continue
                    }

                    let copiedActions = update.atomicActions.map { action in
                        AtomicAction(
                            semantics: action.semantics,
                            actionTag: action.actionTag,
                            stitchTag: action.stitchTag,
                            instruction: action.instruction,
                            producedStitches: action.producedStitches,
                            note: action.note,
                            sequenceIndex: action.sequenceIndex
                        )
                    }

                    records[projectIndex].project.parts[pIdx].rounds[rIdx].atomicActions = copiedActions
                    // Only backfill the target for macro-repeat siblings that had no declared target —
                    // see the matching note in applyAtomizedUpdates above.
                    if records[projectIndex].project.parts[pIdx].rounds[rIdx].targetStitchCount == nil {
                        records[projectIndex].project.parts[pIdx].rounds[rIdx].targetStitchCount = update.producedStitchCount
                    }
                    records[projectIndex].project.parts[pIdx].rounds[rIdx].atomizationStatus = .ready
                    records[projectIndex].project.parts[pIdx].rounds[rIdx].atomizationError = nil
                    records[projectIndex].project.parts[pIdx].rounds[rIdx].atomizationWarning = update.warning
                }
            }
        }
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

    @discardableResult
    private func setExecutionState(_ state: ProjectExecutionState, for projectID: UUID) -> Int {
        let nextToken = (executionStateTokens[projectID] ?? 0) &+ 1
        executionStateTokens[projectID] = nextToken
        executionStates[projectID] = state
        pushActiveSnapshot()
        return nextToken
    }

    /// Writes `state` only when `expectedToken` is still the latest token for `projectID`.
    /// Used by `atomizeTargets` to ensure its terminal state write does not clobber a
    /// newer operation that has already taken control of the project's state.
    private func setExecutionStateIfCurrent(
        _ state: ProjectExecutionState,
        for projectID: UUID,
        expectedToken: Int
    ) {
        guard executionStateTokens[projectID] == expectedToken else { return }
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
        var readyRecord = record
        readyRecord.importState = .ready()
        readyRecord.importRequest = nil
        if let existingIndex = records.firstIndex(where: { $0.project.id == record.project.id }) {
            records[existingIndex] = readyRecord
        } else {
            records.insert(readyRecord, at: 0)
        }
        setExecutionState(.idle, for: readyRecord.project.id)
        activeProjectID = readyRecord.project.id
        persist()
        pushActiveSnapshot()
        autoParseFirstRound(for: readyRecord.project.id)
    }

    /// Automatically atomizes the first round of a newly imported deferred-atomization
    /// project so it is ready when the user enters execution.
    private func autoParseFirstRound(for projectID: UUID) {
        guard let record = record(for: projectID),
              record.project.source.type.supportsDeferredAtomization,
              record.project.parts.first?.rounds.first?.atomizationStatus == .pending else {
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            // Re-check state inside Task to avoid racing with prepareExecution
            guard !self.executionState(for: projectID).isBusy,
                  let currentRecord = self.record(for: projectID),
                  let firstPart = currentRecord.project.parts.first,
                  let firstRound = firstPart.rounds.first,
                  firstRound.atomizationStatus == .pending else {
                return
            }
            _ = await self.atomizeTargets(
                [RoundReference(partID: firstPart.id, roundID: firstRound.id)],
                in: projectID,
                pendingState: .bootstrapping,
                prefetchNext: false
            )
        }
    }

    private func load() {
        let loadedRecords = (try? storage.load([ProjectRecord].self, from: filename)) ?? []
        records = loadedRecords.map { record in
            var updated = record
            if updated.importState.isInProgress {
                updated.importState.fail(message: "导入被中断，请重试。")
            }
            return updated
        }
        activeProjectID = records.first(where: { $0.importState.isReady })?.project.id
        executionStates = Dictionary(uniqueKeysWithValues: records.map { ($0.project.id, .idle) })
        persist()
    }

    private func persist() {
        try? storage.save(records, to: filename)
    }

    private func pushActiveSnapshot() {
        guard let record = activeRecord,
              let snapshot = snapshot(for: record.project.id) else { return }
        Task {
            await watchSync?.push(snapshot: snapshot)
        }
    }
}
