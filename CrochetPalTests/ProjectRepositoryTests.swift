import XCTest
@testable import CrochetPal

@MainActor
final class ProjectRepositoryTests: XCTestCase {
    func testPrepareExecutionAtomizesFirstPendingRoundThenAutoParseNext() async throws {
        let importer = FakePatternImporter(record: makePendingWebRecord())
        let repository = ProjectRepository(
            importer: importer,
            storage: JSONFileStore(directoryURL: tempDirectory()),
            logger: ConsoleTraceLogger()
        )

        let record = try await repository.importWebPattern(from: "https://example.com/pattern")
        await repository.prepareExecution(projectID: record.project.id)

        // prepareExecution parses round 0 (limit:1), then auto-parse starts round 1 in background
        await waitUntil {
            importer.atomizeRequestCounts == [1, 1]
        }

        let updated = try XCTUnwrap(repository.records.first)
        let statuses = updated.project.parts.flatMap(\.rounds).map(\.atomizationStatus)
        XCTAssertEqual(statuses, [.ready, .ready, .pending])
        XCTAssertEqual(importer.atomizeRequestCounts, [1, 1])
    }

    func testPrepareExecutionDoesNotRebootstrapWhenCurrentRoundIsAlreadyReady() async throws {
        let importer = FakePatternImporter(record: makePendingWebRecord())
        let repository = ProjectRepository(
            importer: importer,
            storage: JSONFileStore(directoryURL: tempDirectory()),
            logger: ConsoleTraceLogger()
        )

        let record = try await repository.importWebPattern(from: "https://example.com/pattern")
        await repository.prepareExecution(projectID: record.project.id)

        await waitUntil {
            importer.atomizeRequestCounts == [1, 1]
        }

        await repository.prepareExecution(projectID: record.project.id)

        let updated = try XCTUnwrap(repository.records.first)
        let statuses = updated.project.parts.flatMap(\.rounds).map(\.atomizationStatus)
        XCTAssertEqual(statuses, [.ready, .ready, .pending])
        XCTAssertEqual(importer.atomizeRequestCounts, [1, 1])
    }

    func testContinueExecutionPrefetchesNextPendingRoundAfterRoundCompletion() async throws {
        let importer = FakePatternImporter(record: makePendingWebRecord())
        let repository = ProjectRepository(
            importer: importer,
            storage: JSONFileStore(directoryURL: tempDirectory()),
            logger: ConsoleTraceLogger()
        )

        let record = try await repository.importWebPattern(from: "https://example.com/pattern")
        await repository.prepareExecution(projectID: record.project.id)

        // Wait for initial parse of round 0 and auto-parse of round 1
        await waitUntil {
            importer.atomizeRequestCounts == [1, 1]
        }

        // Advance to end of round 0
        await repository.continueExecution(projectID: record.project.id, source: .phoneButton)
        // Enter round 1 → triggers auto-parse of round 2
        await repository.continueExecution(projectID: record.project.id, source: .phoneButton)
        // Advance to end of round 1
        await repository.continueExecution(projectID: record.project.id, source: .phoneButton)

        await waitUntil {
            importer.atomizeRequestCounts == [1, 1, 1]
        }

        let waiting = try XCTUnwrap(repository.records.first)
        let statuses = waiting.project.parts.flatMap(\.rounds).map(\.atomizationStatus)
        XCTAssertEqual(statuses, [.ready, .ready, .ready])
        XCTAssertEqual(waiting.progress.cursor.partID, waiting.project.parts[0].id)
        XCTAssertEqual(waiting.progress.cursor.roundIndex, 1)
        XCTAssertEqual(waiting.progress.cursor.actionIndex, 1)
        XCTAssertTrue(ExecutionEngine.isAwaitingNextRound(in: waiting.project, progress: waiting.progress))
        XCTAssertEqual(importer.atomizeRequestCounts, [1, 1, 1])

        // Enter round 2 (Part1/Round0)
        await repository.continueExecution(projectID: record.project.id, source: .phoneButton)

        let updated = try XCTUnwrap(repository.records.first)
        XCTAssertEqual(updated.progress.cursor.partID, updated.project.parts[1].id)
        XCTAssertEqual(updated.progress.cursor.roundIndex, 0)
        XCTAssertEqual(updated.progress.cursor.actionIndex, 0)
    }

    func testContinueExecutionAllowsEnteringPendingNextRoundWhileAtomizationRuns() async throws {
        let importer = FakePatternImporter(record: makePendingWebRecord()) { _, targets, callIndex in
            if callIndex == 1 {
                // Auto-parse of round 1 is slow, simulating user entering it mid-parse
                try await Task.sleep(nanoseconds: 200_000_000)
            }
            return FakePatternImporter.defaultAtomizedUpdates(for: targets)
        }
        let repository = ProjectRepository(
            importer: importer,
            storage: JSONFileStore(directoryURL: tempDirectory()),
            logger: ConsoleTraceLogger()
        )

        let record = try await repository.importWebPattern(from: "https://example.com/pattern")
        await repository.prepareExecution(projectID: record.project.id)

        // Wait for auto-parse of round 1 to start (slow, so it'll be in parsingNextRound state)
        await waitUntil {
            repository.executionState(for: record.project.id) == .parsingNextRound
        }

        // Advance to end of round 0
        await repository.continueExecution(projectID: record.project.id, source: .phoneButton)
        // Enter round 1 while it's still being parsed
        await repository.continueExecution(projectID: record.project.id, source: .phoneButton)

        let updated = try XCTUnwrap(repository.records.first)
        let currentRound = try XCTUnwrap(ExecutionEngine.currentRound(in: updated.project, progress: updated.progress))
        XCTAssertEqual(updated.progress.cursor.partID, updated.project.parts[0].id)
        XCTAssertEqual(updated.progress.cursor.roundIndex, 1)
        XCTAssertEqual(updated.progress.cursor.actionIndex, 0)
        XCTAssertEqual(currentRound.atomizationStatus, .pending)
        XCTAssertEqual(repository.executionState(for: record.project.id), .parsingNextRound)
    }

    func testFailedNextRoundPrefetchKeepsIdleStateForCurrentRound() async throws {
        let importer = FakePatternImporter(record: makePendingWebRecord()) { _, targets, callIndex in
            if callIndex == 2 {
                // Auto-parse of round 2 fails when user enters round 1
                throw PatternImportFailure.atomizationFailed("next round failed")
            }
            return FakePatternImporter.defaultAtomizedUpdates(for: targets)
        }
        let repository = ProjectRepository(
            importer: importer,
            storage: JSONFileStore(directoryURL: tempDirectory()),
            logger: ConsoleTraceLogger()
        )

        let record = try await repository.importWebPattern(from: "https://example.com/pattern")
        await repository.prepareExecution(projectID: record.project.id)

        // Wait for initial parse of round 0 and auto-parse of round 1
        await waitUntil {
            importer.atomizeRequestCounts == [1, 1]
        }

        // Advance to end of round 0
        await repository.continueExecution(projectID: record.project.id, source: .phoneButton)
        // Enter round 1 → triggers auto-parse of round 2 which fails
        await repository.continueExecution(projectID: record.project.id, source: .phoneButton)

        await waitUntil {
            guard let updated = repository.records.first else { return false }
            return updated.project.parts[1].rounds[0].atomizationStatus == .failed
        }

        // User is on round 1, state should be idle despite round 2 failure
        let onRound1 = try XCTUnwrap(repository.records.first)
        let round1Snapshot = try XCTUnwrap(repository.snapshot(for: record.project.id))
        XCTAssertEqual(repository.executionState(for: record.project.id), .idle)
        XCTAssertEqual(onRound1.progress.cursor.partID, onRound1.project.parts[0].id)
        XCTAssertEqual(onRound1.progress.cursor.roundIndex, 1)
        XCTAssertEqual(onRound1.progress.cursor.actionIndex, 0)
        XCTAssertTrue(round1Snapshot.canAdvance)

        // Advance through round 1
        await repository.continueExecution(projectID: record.project.id, source: .phoneButton)
        // Enter round 2 (Part1/Round0) → handleRoundDidAppear detects .failed
        await repository.continueExecution(projectID: record.project.id, source: .phoneButton)

        let failedRoundSnapshot = try XCTUnwrap(repository.snapshot(for: record.project.id))
        XCTAssertEqual(failedRoundSnapshot.roundTitle, "Eye Round 1")
        XCTAssertEqual(failedRoundSnapshot.actionTitle, "Blocked")
        XCTAssertFalse(failedRoundSnapshot.canAdvance)
    }

    func testPrepareExecutionAtomizesFirstPendingRoundThenAutoParseNextForTextProject() async throws {
        let importer = FakePatternImporter(record: makePendingRecord(sourceType: .text))
        let repository = ProjectRepository(
            importer: importer,
            storage: JSONFileStore(directoryURL: tempDirectory()),
            logger: ConsoleTraceLogger()
        )

        let record = try await repository.importTextPattern(from: "Mouse Cat Toy\nRound 1: In a MR, sc 6. (6)")
        await repository.prepareExecution(projectID: record.project.id)

        await waitUntil {
            importer.atomizeRequestCounts == [1, 1]
        }

        let updated = try XCTUnwrap(repository.records.first)
        let statuses = updated.project.parts.flatMap(\.rounds).map(\.atomizationStatus)
        XCTAssertEqual(updated.project.source.type, .text)
        XCTAssertEqual(statuses, [.ready, .ready, .pending])
        XCTAssertEqual(importer.atomizeRequestCounts, [1, 1])
    }

    func testRegenerateRoundReatomizesRequestedRoundAndAutoParseNext() async throws {
        let importer = FakePatternImporter(record: makePendingWebRecord())
        let repository = ProjectRepository(
            importer: importer,
            storage: JSONFileStore(directoryURL: tempDirectory()),
            logger: ConsoleTraceLogger()
        )

        let record = try await repository.importWebPattern(from: "https://example.com/pattern")
        let firstPartID = try XCTUnwrap(record.project.parts.first?.id)
        let firstRoundID = try XCTUnwrap(record.project.parts.first?.rounds.first?.id)

        await repository.regenerateRound(
            projectID: record.project.id,
            partID: firstPartID,
            roundID: firstRoundID
        )

        // Regeneration atomized round 0, then auto-parse starts round 1 in background
        await waitUntil {
            importer.atomizeRequestCounts == [1, 1]
        }

        let updated = try XCTUnwrap(repository.records.first)
        let statuses = updated.project.parts.flatMap(\.rounds).map(\.atomizationStatus)
        XCTAssertEqual(statuses, [.ready, .ready, .pending])
        XCTAssertEqual(importer.atomizeRequestCounts, [1, 1])
        // Verify regeneration call targeted only the requested round
        XCTAssertEqual(importer.requestedTargets[0], [RoundReference(partID: firstPartID, roundID: firstRoundID)])
    }

    func testClearRecentLogsRemovesCapturedEvents() async throws {
        let logger = ConsoleTraceLogger()
        let repository = ProjectRepository(
            importer: FakePatternImporter(record: makePendingWebRecord()),
            storage: JSONFileStore(directoryURL: tempDirectory()),
            logger: logger
        )

        logger.log(
            LogEvent(
                timestamp: .now,
                level: "debug",
                traceID: "trace",
                parseRequestID: nil,
                projectID: nil,
                sourceType: .web,
                stage: "parse",
                decision: "success",
                reason: "captured",
                durationMS: nil,
                metadata: [:]
            )
        )

        await waitUntil {
            repository.recentLogs.count == 1
        }

        repository.clearRecentLogs()

        XCTAssertTrue(repository.recentLogs.isEmpty)
    }

    private func tempDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func makePendingWebRecord() -> ProjectRecord {
        makePendingRecord(sourceType: .web)
    }

    private func makePendingRecord(sourceType: PatternSourceType) -> ProjectRecord {
        let parts = SampleDataFactory.demoOutlineResponse.parts.map { part in
            PatternPart(
                name: part.name,
                rounds: part.rounds.map { round in
                    PatternRound(
                        title: round.title,
                        rawInstruction: round.rawInstruction,
                        summary: round.summary,
                        targetStitchCount: round.targetStitchCount,
                        atomizationStatus: .pending,
                        atomizationError: nil,
                        atomicActions: []
                    )
                }
            )
        }

        let project = CrochetProject(
            title: SampleDataFactory.demoOutlineResponse.projectTitle,
            source: PatternSource(
                type: sourceType,
                displayName: sourceType == .text ? "Pasted Pattern" : "Preview",
                sourceURL: sourceType == .web ? "https://example.com/pattern" : nil,
                fileName: nil,
                fileSizeBytes: 128,
                importedAt: .now
            ),
            materials: SampleDataFactory.demoOutlineResponse.materials,
            confidence: SampleDataFactory.demoOutlineResponse.confidence,
            parts: parts,
            activePartID: parts.first?.id,
            createdAt: .now,
            updatedAt: .now
        )

        return ProjectRecord(project: project, progress: .initial(for: project))
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 1_000_000_000,
        condition: @escaping @MainActor () -> Bool
    ) async {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if condition() {
                return
            }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTFail("Condition not met before timeout")
    }
}

private final class FakePatternImporter: PatternImporting {
    private let record: ProjectRecord
    private let atomizeBehavior: @Sendable (CrochetProject, [RoundReference], Int) async throws -> [AtomizedRoundUpdate]
    private(set) var atomizeRequestCounts: [Int] = []
    private(set) var requestedTargets: [[RoundReference]] = []

    init(
        record: ProjectRecord,
        atomizeBehavior: @escaping @Sendable (CrochetProject, [RoundReference], Int) async throws -> [AtomizedRoundUpdate] = { _, targets, _ in
            FakePatternImporter.defaultAtomizedUpdates(for: targets)
        }
    ) {
        self.record = record
        self.atomizeBehavior = atomizeBehavior
    }

    func importWebPattern(from urlString: String) async throws -> ProjectRecord {
        record
    }

    func importImagePattern(data: Data, fileName: String) async throws -> ProjectRecord {
        record
    }

    func importTextPattern(from rawText: String) async throws -> ProjectRecord {
        record
    }

    func atomizeRounds(in project: CrochetProject, targets: [RoundReference]) async throws -> [AtomizedRoundUpdate] {
        let callIndex = atomizeRequestCounts.count
        atomizeRequestCounts.append(targets.count)
        requestedTargets.append(targets)
        return try await atomizeBehavior(project, targets, callIndex)
    }

    static func defaultAtomizedUpdates(for targets: [RoundReference]) -> [AtomizedRoundUpdate] {
        targets.map { target in
            AtomizedRoundUpdate(
                reference: target,
                atomicActions: [
                    AtomicAction(type: .sc, instruction: "sc", producedStitches: 1, sequenceIndex: 0)
                ]
            )
        }
    }
}
