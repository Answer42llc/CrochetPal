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

    func testStartWebImportInsertsPlaceholderBeforeImporterCompletesAndReplacesSameID() async throws {
        let importer = FakePatternImporter(
            record: makePendingWebRecord(),
            importBehavior: { [self] _ in
                try await Task.sleep(nanoseconds: 200_000_000)
                return self.makePendingWebRecord()
            }
        )
        let repository = ProjectRepository(
            importer: importer,
            storage: JSONFileStore(directoryURL: tempDirectory()),
            logger: ConsoleTraceLogger(),
            backgroundTaskRunner: NoopBackgroundTaskRunner()
        )

        let projectID = try repository.startWebImport(from: "https://example.com/pattern")

        XCTAssertEqual(repository.records.count, 1)
        XCTAssertEqual(repository.records.first?.project.id, projectID)
        XCTAssertEqual(repository.records.first?.project.title, "Importing Web Pattern")
        XCTAssertFalse(repository.records.first?.importState.isReady ?? true)

        await waitUntil {
            repository.records.first?.importState.isReady == true
        }

        let completed = try XCTUnwrap(repository.records.first)
        XCTAssertEqual(completed.project.id, projectID)
        XCTAssertEqual(completed.project.title, "Mouse Cat Toy")
        XCTAssertNil(completed.importRequest)
    }

    func testCompletedAsyncImportRequestsPermissionAndSchedulesCompletionNotification() async throws {
        let importer = FakePatternImporter(record: makePendingWebRecord())
        let notifications = SpyImportNotificationScheduler()
        let repository = ProjectRepository(
            importer: importer,
            storage: JSONFileStore(directoryURL: tempDirectory()),
            logger: ConsoleTraceLogger(),
            backgroundTaskRunner: NoopBackgroundTaskRunner(),
            importNotificationScheduler: notifications
        )

        let projectID = try repository.startWebImport(from: "https://example.com/pattern")

        await waitUntil {
            notifications.prepareCount == 1 &&
                notifications.completedImports.contains { completed in
                    completed.projectID == projectID && completed.projectTitle == "Mouse Cat Toy"
                }
        }
    }

    func testFailedAsyncImportDoesNotScheduleCompletionNotification() async throws {
        let importer = FakePatternImporter(
            record: makePendingWebRecord(),
            importBehavior: { _ in
                throw PatternImportFailure.emptyExtraction
            }
        )
        let notifications = SpyImportNotificationScheduler()
        let repository = ProjectRepository(
            importer: importer,
            storage: JSONFileStore(directoryURL: tempDirectory()),
            logger: ConsoleTraceLogger(),
            backgroundTaskRunner: NoopBackgroundTaskRunner(),
            importNotificationScheduler: notifications
        )

        _ = try repository.startWebImport(from: "https://example.com/pattern")

        await waitUntil {
            repository.records.first?.importState.isFailed == true &&
                notifications.prepareCount == 1
        }
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertTrue(notifications.completedImports.isEmpty)
    }

    func testCompletedAsyncImportStillAutoParsesFirstDeferredRound() async throws {
        let importer = FakePatternImporter(record: makePendingWebRecord())
        let repository = ProjectRepository(
            importer: importer,
            storage: JSONFileStore(directoryURL: tempDirectory()),
            logger: ConsoleTraceLogger(),
            backgroundTaskRunner: NoopBackgroundTaskRunner()
        )

        let projectID = try repository.startWebImport(from: "https://example.com/pattern")

        await waitUntil {
            importer.atomizeRequestCounts == [1]
        }

        let completed = try XCTUnwrap(repository.records.first(where: { $0.project.id == projectID }))
        XCTAssertEqual(completed.importState.phase, .ready)
        XCTAssertEqual(completed.project.parts[0].rounds[0].atomizationStatus, .ready)
    }

    func testFailedAsyncImportKeepsRequestAndRetryReusesSameRow() async throws {
        let importer = FakePatternImporter(
            record: makePendingWebRecord(),
            importBehavior: { [self] callIndex in
                if callIndex == 0 {
                    throw PatternImportFailure.emptyExtraction
                }
                return self.makePendingWebRecord()
            }
        )
        let repository = ProjectRepository(
            importer: importer,
            storage: JSONFileStore(directoryURL: tempDirectory()),
            logger: ConsoleTraceLogger(),
            backgroundTaskRunner: NoopBackgroundTaskRunner()
        )

        let projectID = try repository.startWebImport(from: "https://example.com/pattern")

        await waitUntil {
            repository.records.first?.importState.isFailed == true
        }

        let failed = try XCTUnwrap(repository.records.first)
        XCTAssertEqual(failed.project.id, projectID)
        XCTAssertNotNil(failed.importRequest)
        XCTAssertEqual(importer.importRequestCount, 1)

        repository.retryImport(projectID: projectID)

        await waitUntil {
            repository.records.first?.importState.isReady == true
        }

        let completed = try XCTUnwrap(repository.records.first)
        XCTAssertEqual(completed.project.id, projectID)
        XCTAssertNil(completed.importRequest)
        XCTAssertEqual(importer.importRequestCount, 2)
    }

    func testLoadMarksInterruptedImportsAsRetryableFailures() async throws {
        let directory = tempDirectory()
        let storage = JSONFileStore(directoryURL: directory)
        let now = Date()
        let project = CrochetProject(
            title: "Importing Web Pattern",
            source: PatternSource(
                type: .web,
                displayName: "https://example.com/pattern",
                sourceURL: "https://example.com/pattern",
                fileName: nil,
                fileSizeBytes: nil,
                importedAt: now
            ),
            materials: [],
            confidence: 0,
            abbreviations: [],
            parts: [],
            activePartID: nil,
            createdAt: now,
            updatedAt: now
        )
        let interrupted = ProjectRecord(
            project: project,
            progress: .initial(for: project),
            importState: PatternImportState(phase: .parsingOutline, message: "正在解析 Pattern 结构", errorMessage: nil, updatedAt: now, retryCount: 0),
            importRequest: .web(urlString: "https://example.com/pattern")
        )
        try storage.save([interrupted], to: "projects.json")

        let repository = ProjectRepository(
            importer: FakePatternImporter(record: makePendingWebRecord()),
            storage: storage,
            logger: ConsoleTraceLogger(),
            backgroundTaskRunner: NoopBackgroundTaskRunner()
        )

        let record = try XCTUnwrap(repository.records.first)
        XCTAssertTrue(record.importState.isFailed)
        XCTAssertEqual(record.importState.errorMessage, "导入被中断，请重试。")
        XCTAssertNotNil(record.importRequest)
    }

    func testStartTextImageAndPDFImportsCopyRetrySources() async throws {
        let sourceStore = SourceFileStore(baseDirectoryURL: tempDirectory())
        let importer = FakePatternImporter(
            record: makePendingWebRecord(),
            importBehavior: { [self] _ in
                try await Task.sleep(nanoseconds: 500_000_000)
                return self.makePendingWebRecord()
            }
        )
        let repository = ProjectRepository(
            importer: importer,
            storage: JSONFileStore(directoryURL: tempDirectory()),
            logger: ConsoleTraceLogger(),
            sourceFileStore: sourceStore,
            backgroundTaskRunner: NoopBackgroundTaskRunner()
        )

        let textID = try repository.startTextImport(from: "Round 1: sc 6")
        let imageData = Data([0x01, 0x02, 0x03])
        let imageID = try repository.startImageImport(data: imageData, fileName: "pattern.png")
        let pdfData = Data([0x25, 0x50, 0x44, 0x46])
        let pdfID = try repository.startPDFImport(data: pdfData, fileName: "pattern.pdf")

        let textRecord = try XCTUnwrap(repository.records.first(where: { $0.project.id == textID }))
        let textRequest = try XCTUnwrap(textRecord.importRequest)
        XCTAssertEqual(textRequest.sourceType, .text)
        let textPath = try XCTUnwrap(textRequest.localFilePath)
        let textURL = try XCTUnwrap(sourceStore.resolveURL(forRelativePath: textPath))
        XCTAssertEqual(try String(contentsOf: textURL, encoding: .utf8), "Round 1: sc 6")

        let imageRecord = try XCTUnwrap(repository.records.first(where: { $0.project.id == imageID }))
        let imageRequest = try XCTUnwrap(imageRecord.importRequest)
        XCTAssertEqual(imageRequest.sourceType, .image)
        let imagePath = try XCTUnwrap(imageRequest.localFilePath)
        XCTAssertEqual(imageRequest.fileName, "pattern.png")
        XCTAssertEqual(imageRequest.fileSizeBytes, imageData.count)
        let imageURL = try XCTUnwrap(sourceStore.resolveURL(forRelativePath: imagePath))
        XCTAssertEqual(try Data(contentsOf: imageURL), imageData)

        let pdfRecord = try XCTUnwrap(repository.records.first(where: { $0.project.id == pdfID }))
        let pdfRequest = try XCTUnwrap(pdfRecord.importRequest)
        XCTAssertEqual(pdfRequest.sourceType, .pdf)
        let pdfPath = try XCTUnwrap(pdfRequest.localFilePath)
        XCTAssertEqual(pdfRequest.fileName, "pattern.pdf")
        XCTAssertEqual(pdfRequest.fileSizeBytes, pdfData.count)
        let pdfURL = try XCTUnwrap(sourceStore.resolveURL(forRelativePath: pdfPath))
        XCTAssertEqual(try Data(contentsOf: pdfURL), pdfData)

        let projectIDs = [textID, imageID, pdfID]
        await waitUntil(timeoutNanoseconds: 2_000_000_000) {
            projectIDs.allSatisfy { id in
                repository.records.first(where: { $0.project.id == id })?.importState.isReady == true
            }
        }
    }

    // Regression for the Round 7 "Complete + 0/0" bug: when the LLM atomization returns
    // zero atomic actions (e.g. the produced count is 0 because every stitch was wrapped
    // in a note(emitAsAction=false) — see docs/bad-cases/round7-...md), the repository
    // must not overwrite the round's declared targetStitchCount with that produced count.
    // Otherwise the "(12)" the outline stage parsed from the raw pattern text is erased
    // and the UI can no longer show the user the real target.
    func testApplyAtomizedUpdatesPreservesExplicitTargetStitchCount() async throws {
        let importer = FakePatternImporter(
            record: makePendingWebRecord(),
            atomizeBehavior: { _, targets, _ in
                targets.map { target in
                    AtomizedRoundUpdate(
                        reference: target,
                        atomicActions: [],
                        producedStitchCount: 0,
                        warning: "atomization_target_stitch_count_mismatch"
                    )
                }
            }
        )
        let repository = ProjectRepository(
            importer: importer,
            storage: JSONFileStore(directoryURL: tempDirectory()),
            logger: ConsoleTraceLogger()
        )

        let record = try await repository.importWebPattern(from: "https://example.com/pattern")
        let originalTargets = record.project.parts.flatMap(\.rounds).map(\.targetStitchCount)
        XCTAssertTrue(
            originalTargets.contains(where: { $0 != nil }),
            "Fixture sanity check: at least one outline round should have an explicit target."
        )

        await repository.prepareExecution(projectID: record.project.id)
        await waitUntil {
            importer.atomizeRequestCounts == [1, 1]
        }

        let updated = try XCTUnwrap(repository.records.first)
        let roundsAfter = updated.project.parts.flatMap(\.rounds)
        for (index, round) in roundsAfter.enumerated() where round.atomizationStatus == .ready {
            XCTAssertEqual(
                round.targetStitchCount,
                originalTargets[index],
                "Round \(index) targetStitchCount must not be overwritten after atomization (before=\(String(describing: originalTargets[index])), after=\(String(describing: round.targetStitchCount)))."
            )
        }
    }

    // Complementary case: when the outline stage didn't parse an explicit target (e.g.
    // the pattern text didn't end with "(N)"), the produced count is allowed to backfill
    // so the progress bar still has something to show.
    func testApplyAtomizedUpdatesBackfillsTargetStitchCountWhenNilFromOutline() async throws {
        var seedRecord = makePendingWebRecord()
        for partIndex in seedRecord.project.parts.indices {
            for roundIndex in seedRecord.project.parts[partIndex].rounds.indices {
                seedRecord.project.parts[partIndex].rounds[roundIndex].targetStitchCount = nil
            }
        }
        let importer = FakePatternImporter(
            record: seedRecord,
            atomizeBehavior: { _, targets, _ in
                targets.map { target in
                    AtomizedRoundUpdate(
                        reference: target,
                        atomicActions: [
                            AtomicAction(semantics: .stitchProducing, actionTag: "sc", stitchTag: "sc", instruction: "sc", producedStitches: 1, sequenceIndex: 0)
                        ],
                        producedStitchCount: 7,
                        warning: nil
                    )
                }
            }
        )
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

        let updated = try XCTUnwrap(repository.records.first)
        let readyRounds = updated.project.parts.flatMap(\.rounds).filter { $0.atomizationStatus == .ready }
        XCTAssertFalse(readyRounds.isEmpty)
        for round in readyRounds {
            XCTAssertEqual(
                round.targetStitchCount, 7,
                "When outline didn't set a target, atomization's producedStitchCount should backfill it."
            )
        }
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
            abbreviations: [],
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
    private let importBehavior: (Int) async throws -> ProjectRecord
    private let atomizeBehavior: @Sendable (CrochetProject, [RoundReference], Int) async throws -> [AtomizedRoundUpdate]
    private(set) var importRequestCount = 0
    private(set) var atomizeRequestCounts: [Int] = []
    private(set) var requestedTargets: [[RoundReference]] = []

    init(
        record: ProjectRecord,
        importBehavior: ((Int) async throws -> ProjectRecord)? = nil,
        atomizeBehavior: @escaping @Sendable (CrochetProject, [RoundReference], Int) async throws -> [AtomizedRoundUpdate] = { _, targets, _ in
            FakePatternImporter.defaultAtomizedUpdates(for: targets)
        }
    ) {
        self.record = record
        self.importBehavior = importBehavior ?? { _ in record }
        self.atomizeBehavior = atomizeBehavior
    }

    func importWebPattern(from urlString: String) async throws -> ProjectRecord {
        try await importRecord()
    }

    func importImagePattern(data: Data, fileName: String) async throws -> ProjectRecord {
        try await importRecord()
    }

    func importTextPattern(from rawText: String) async throws -> ProjectRecord {
        try await importRecord()
    }

    func importPDFPattern(data: Data, fileName: String) async throws -> ProjectRecord {
        try await importRecord()
    }

    private func importRecord() async throws -> ProjectRecord {
        let callIndex = importRequestCount
        importRequestCount += 1
        return try await importBehavior(callIndex)
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
                    AtomicAction(semantics: .stitchProducing, actionTag: "sc", stitchTag: "sc", instruction: "sc", producedStitches: 1, sequenceIndex: 0)
                ],
                producedStitchCount: 1
            )
        }
    }
}

private final class SpyImportNotificationScheduler: ImportNotificationScheduling {
    private(set) var prepareCount = 0
    private(set) var completedImports: [(projectID: UUID, projectTitle: String)] = []

    func prepareForImportCompletionNotifications() async {
        prepareCount += 1
    }

    func notifyImportCompleted(projectID: UUID, projectTitle: String) async {
        completedImports.append((projectID, projectTitle))
    }
}
