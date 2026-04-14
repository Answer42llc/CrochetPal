import Foundation

struct AtomizedRoundUpdate: Hashable {
    var reference: RoundReference
    var atomicActions: [AtomicAction]
}

protocol PatternImporting {
    func importWebPattern(from urlString: String) async throws -> ProjectRecord
    func importTextPattern(from rawText: String) async throws -> ProjectRecord
    func importImagePattern(data: Data, fileName: String) async throws -> ProjectRecord
    func atomizeRounds(in project: CrochetProject, targets: [RoundReference]) async throws -> [AtomizedRoundUpdate]
}

struct PatternImportService: PatternImporting {
    private let parserClient: PatternLLMParsing
    private let extractor: HTMLExtracting
    private let session: URLSession
    private let logger: TraceLogging

    init(
        parserClient: PatternLLMParsing,
        extractor: HTMLExtracting,
        session: URLSession = .shared,
        logger: TraceLogging
    ) {
        self.parserClient = parserClient
        self.extractor = extractor
        self.session = session
        self.logger = logger
    }

    func importWebPattern(from urlString: String) async throws -> ProjectRecord {
        guard let url = URL(string: urlString) else {
            throw PatternImportFailure.invalidURL
        }

        let context = ParseRequestContext(
            traceID: UUID().uuidString,
            parseRequestID: UUID().uuidString,
            sourceType: .web
        )

        let request = URLRequest(url: url)
        let started = Date()
        let (data, response) = try await session.data(for: request)
        let duration = Int(Date().timeIntervalSince(started) * 1000)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PatternImportFailure.invalidResponse("missing_http_response")
        }
        guard 200..<300 ~= httpResponse.statusCode else {
            throw PatternImportFailure.fetchFailed(statusCode: httpResponse.statusCode)
        }

        let html = String(decoding: data, as: UTF8.self)
        logger.log(LogEvent(
            timestamp: .now,
            level: "debug",
            traceID: context.traceID,
            parseRequestID: context.parseRequestID,
            projectID: nil,
            sourceType: .web,
            stage: "web_fetch",
            decision: "success",
            reason: "downloaded_html",
            durationMS: duration,
            metadata: ["statusCode": "\(httpResponse.statusCode)", "bytes": "\(data.count)", "url": url.absoluteString]
        ))

        let extraction = extractor.extract(from: html, sourceURL: url, context: context, logger: logger)
        logger.log(LogEvent(
            timestamp: .now,
            level: "debug",
            traceID: context.traceID,
            parseRequestID: context.parseRequestID,
            projectID: nil,
            sourceType: .web,
            stage: "web_outline_payload",
            decision: "prepared_final_text",
            reason: "sending_outline_text_to_llm",
            durationMS: nil,
            metadata: [
                "url": url.absoluteString,
                "titleHint": extraction.title ?? "",
                "finalText": extraction.finalText
            ]
        ))
        guard !extraction.finalText.isEmpty else {
            throw PatternImportFailure.emptyExtraction
        }

        let responsePayload = try await parserClient.parseTextPatternOutline(
            extractedText: extraction.finalText,
            titleHint: extraction.title,
            context: context
        )

        return makeOutlineRecord(
            from: responsePayload,
            source: PatternSource(
                type: .web,
                displayName: extraction.title ?? url.host ?? url.absoluteString,
                sourceURL: url.absoluteString,
                fileName: nil,
                fileSizeBytes: data.count,
                importedAt: .now
            ),
            context: context
        )
    }

    func importTextPattern(from rawText: String) async throws -> ProjectRecord {
        let trimmedText = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            throw PatternImportFailure.emptyExtraction
        }

        let context = ParseRequestContext(
            traceID: UUID().uuidString,
            parseRequestID: UUID().uuidString,
            sourceType: .text
        )

        logger.log(LogEvent(
            timestamp: .now,
            level: "debug",
            traceID: context.traceID,
            parseRequestID: context.parseRequestID,
            projectID: nil,
            sourceType: .text,
            stage: "text_outline_payload",
            decision: "prepared_final_text",
            reason: "sending_outline_text_to_llm",
            durationMS: nil,
            metadata: [
                "characterCount": "\(trimmedText.count)",
                "finalText": trimmedText
            ]
        ))

        let responsePayload = try await parserClient.parseTextPatternOutline(
            extractedText: trimmedText,
            titleHint: nil,
            context: context
        )

        return makeOutlineRecord(
            from: responsePayload,
            source: PatternSource(
                type: .text,
                displayName: "Pasted Pattern",
                sourceURL: nil,
                fileName: nil,
                fileSizeBytes: trimmedText.lengthOfBytes(using: .utf8),
                importedAt: .now
            ),
            context: context
        )
    }

    func importImagePattern(data: Data, fileName: String) async throws -> ProjectRecord {
        let context = ParseRequestContext(
            traceID: UUID().uuidString,
            parseRequestID: UUID().uuidString,
            sourceType: .image
        )

        logger.log(LogEvent(
            timestamp: .now,
            level: "debug",
            traceID: context.traceID,
            parseRequestID: context.parseRequestID,
            projectID: nil,
            sourceType: .image,
            stage: "image_import",
            decision: "start",
            reason: "received_image_data",
            durationMS: nil,
            metadata: ["fileName": fileName, "bytes": "\(data.count)"]
        ))

        let responsePayload = try await parserClient.parseImagePattern(
            imageData: data,
            mimeType: mimeType(for: fileName),
            fileName: fileName,
            context: context
        )

        return makeImageRecord(
            from: responsePayload,
            source: PatternSource(
                type: .image,
                displayName: fileName,
                sourceURL: nil,
                fileName: fileName,
                fileSizeBytes: data.count,
                importedAt: .now
            ),
            context: context
        )
    }

    func atomizeRounds(in project: CrochetProject, targets: [RoundReference]) async throws -> [AtomizedRoundUpdate] {
        guard project.source.type.supportsDeferredAtomization else {
            return []
        }
        guard !targets.isEmpty else {
            return []
        }

        let context = ParseRequestContext(
            traceID: UUID().uuidString,
            parseRequestID: UUID().uuidString,
            sourceType: project.source.type
        )

        let inputs = try atomizationInputs(for: project, targets: targets)
        let updates = try await requestAtomization(
            projectTitle: project.title,
            materials: project.materials,
            inputs: inputs,
            targets: targets,
            context: context
        )

        logger.log(LogEvent(
            timestamp: .now,
            level: "debug",
            traceID: context.traceID,
            parseRequestID: context.parseRequestID,
            projectID: project.id,
            sourceType: .web,
            stage: targets.count > 1 ? "execution_bootstrap_atomization" : "execution_incremental_atomization",
            decision: "success",
            reason: "atomized_rounds",
            durationMS: nil,
            metadata: [
                "roundCount": "\(targets.count)",
                "actionCount": "\(updates.reduce(0) { $0 + $1.atomicActions.count })"
            ]
        ))

        return updates
    }

    private func makeOutlineRecord(
        from payload: PatternOutlineResponse,
        source: PatternSource,
        context: ParseRequestContext
    ) -> ProjectRecord {
        let now = Date()
        let parts = payload.parts.map { part in
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
            title: payload.projectTitle,
            source: source,
            materials: payload.materials,
            confidence: payload.confidence,
            parts: parts,
            activePartID: parts.first?.id,
            createdAt: now,
            updatedAt: now
        )
        let progress = ExecutionProgress.initial(for: project)

        logger.log(LogEvent(
            timestamp: .now,
            level: "debug",
            traceID: context.traceID,
            parseRequestID: context.parseRequestID,
            projectID: project.id,
            sourceType: source.type,
            stage: "parse_validation",
            decision: "success",
            reason: "built_outline_project_record",
            durationMS: nil,
            metadata: [
                "partCount": "\(parts.count)",
                "roundCount": "\(parts.flatMap(\.rounds).count)"
            ]
        ))

        return ProjectRecord(project: project, progress: progress)
    }

    private func makeImageRecord(
        from payload: PatternParseResponse,
        source: PatternSource,
        context: ParseRequestContext
    ) -> ProjectRecord {
        let now = Date()
        let parts = payload.parts.map { part in
            PatternPart(
                name: part.name,
                rounds: part.rounds.map { round in
                    let atomicActions = round.atomicActions.enumerated().map { actionIndex, action in
                        AtomicAction(
                            type: action.type,
                            instruction: AtomicAction.normalizedInstruction(action.instruction),
                            producedStitches: action.producedStitches ?? action.type.defaultProducedStitches,
                            note: action.note,
                            sequenceIndex: actionIndex
                        )
                    }

                    return PatternRound(
                        title: round.title,
                        rawInstruction: round.rawInstruction,
                        summary: round.summary,
                        targetStitchCount: round.targetStitchCount,
                        atomizationStatus: .ready,
                        atomizationError: nil,
                        atomicActions: atomicActions
                    )
                }
            )
        }

        let project = CrochetProject(
            title: payload.projectTitle,
            source: source,
            materials: payload.materials,
            confidence: payload.confidence,
            parts: parts,
            activePartID: parts.first?.id,
            createdAt: now,
            updatedAt: now
        )
        let progress = ExecutionProgress.initial(for: project)

        logger.log(LogEvent(
            timestamp: .now,
            level: "debug",
            traceID: context.traceID,
            parseRequestID: context.parseRequestID,
            projectID: project.id,
            sourceType: source.type,
            stage: "parse_validation",
            decision: "success",
            reason: "built_project_record",
            durationMS: nil,
            metadata: [
                "partCount": "\(parts.count)",
                "roundCount": "\(parts.flatMap(\.rounds).count)",
                "actionCount": "\(project.totalAtomicActionCount)"
            ]
        ))

        return ProjectRecord(project: project, progress: progress)
    }

    private func atomizationInputs(for project: CrochetProject, targets: [RoundReference]) throws -> [AtomizationRoundInput] {
        try targets.map { target in
            guard let part = project.parts.first(where: { $0.id == target.partID }),
                  let round = part.rounds.first(where: { $0.id == target.roundID }) else {
                throw PatternImportFailure.invalidResponse("missing_round_for_atomization")
            }

            return AtomizationRoundInput(
                partName: part.name,
                title: round.title,
                rawInstruction: round.rawInstruction,
                summary: round.summary,
                targetStitchCount: round.targetStitchCount
            )
        }
    }

    private func requestAtomization(
        projectTitle: String,
        materials: [String],
        inputs: [AtomizationRoundInput],
        targets: [RoundReference],
        context: ParseRequestContext
    ) async throws -> [AtomizedRoundUpdate] {
        let response = try await parserClient.atomizeTextRounds(
            projectTitle: projectTitle,
            materials: materials,
            rounds: inputs,
            context: context
        )

        guard response.rounds.count == targets.count else {
            throw PatternImportFailure.inconsistentRound("atomized_round_count_mismatch")
        }

        return try zip(targets, response.rounds).map { target, payload in
            let atomicActions = try buildAtomicActions(from: payload.actionGroups)
            return AtomizedRoundUpdate(reference: target, atomicActions: atomicActions)
        }
    }

    private func buildAtomicActions(from groups: [ParsedActionGroup]) throws -> [AtomicAction] {
        var actions: [AtomicAction] = []
        var sequenceIndex = 0

        for group in groups {
            guard group.count > 0 else {
                throw PatternImportFailure.invalidResponse("invalid_action_group_count")
            }

            for _ in 0..<group.count {
                actions.append(
                    AtomicAction(
                        type: group.type,
                        instruction: AtomicAction.normalizedInstruction(group.instruction),
                        producedStitches: group.producedStitches ?? group.type.defaultProducedStitches,
                        note: group.note,
                        sequenceIndex: sequenceIndex
                    )
                )
                sequenceIndex += 1
            }
        }

        return actions
    }
    private func mimeType(for fileName: String) -> String {
        if fileName.lowercased().hasSuffix(".png") {
            return "image/png"
        }
        if fileName.lowercased().hasSuffix(".webp") {
            return "image/webp"
        }
        return "image/jpeg"
    }
}
