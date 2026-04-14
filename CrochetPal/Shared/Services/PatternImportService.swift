import Foundation

struct AtomizedRoundUpdate: Hashable {
    var reference: RoundReference
    var atomicActions: [AtomicAction]
    var resolvedTargetStitchCount: Int
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
            throw PatternImportFailure.fetchFailed(statusCode: httpResponse.statusCode, details: nil)
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

        return try makeImageRecord(
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
            sourceType: project.source.type,
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
    ) throws -> ProjectRecord {
        let now = Date()
        let parts = try payload.parts.map { part in
            PatternPart(
                name: part.name,
                rounds: try part.rounds.map { round in
                    let atomicActions = try round.atomicActions.enumerated().map { actionIndex, action in
                        try makeAtomicAction(
                            type: action.type,
                            instruction: action.instruction,
                            producedStitches: action.producedStitches,
                            note: action.note,
                            sequenceIndex: actionIndex,
                            failureBuilder: { type in
                                PatternImportFailure.invalidResponse("image_parse_contains_non_action_type:\(type.rawValue)")
                            }
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

        return try zip(zip(targets, inputs), response.rounds).map { entry, payload in
            let (target, input) = entry
            let expansion = try buildAtomicActions(
                from: payload.segments,
                originalTargetStitchCount: input.targetStitchCount
            )
            return AtomizedRoundUpdate(
                reference: target,
                atomicActions: expansion.atomicActions,
                resolvedTargetStitchCount: expansion.resolvedTargetStitchCount
            )
        }
    }

    private func buildAtomicActions(
        from segments: [AtomizedSegment],
        originalTargetStitchCount: Int?
    ) throws -> (atomicActions: [AtomicAction], resolvedTargetStitchCount: Int) {
        let drafts = try expandSegments(segments)
        let atomicActions = try drafts.enumerated().map { index, draft in
            try makeAtomicAction(from: draft, sequenceIndex: index)
        }
        let producedStitchCount = atomicActions.reduce(0) { $0 + $1.producedStitches }

        if let originalTargetStitchCount,
           originalTargetStitchCount != producedStitchCount {
            throw PatternImportFailure.atomizationFailed(
                "atomization_target_stitch_count_mismatch:expected_\(originalTargetStitchCount)_actual_\(producedStitchCount)"
            )
        }

        return (
            atomicActions: atomicActions,
            resolvedTargetStitchCount: originalTargetStitchCount ?? producedStitchCount
        )
    }

    private func expandSegments(_ segments: [AtomizedSegment]) throws -> [ExpandedAtomicAction] {
        try segments.flatMap(expandSegment)
    }

    private func expandSegment(_ segment: AtomizedSegment) throws -> [ExpandedAtomicAction] {
        switch segment {
        case let .stitchRun(run):
            return try expandStitchRun(run)
        case let .repeatBlock(repeatSegment):
            return try expandRepeatSegment(repeatSegment)
        case let .control(control):
            return try expandControlSegment(control)
        }
    }

    private func expandStitchRun(_ segment: StitchRunSegment) throws -> [ExpandedAtomicAction] {
        guard segment.count > 0 else {
            throw PatternImportFailure.invalidResponse("invalid_stitch_run_count")
        }
        guard segment.type.isAtomicActionType else {
            throw PatternImportFailure.atomizationFailed("atomization_contains_non_action_type:\(segment.type.rawValue)")
        }

        var actions = (0..<segment.count).map { _ in
            ExpandedAtomicAction(
                type: segment.type,
                instruction: segment.instruction,
                producedStitches: segment.type.resolvedAtomizationProducedStitches(from: segment.producedStitches),
                note: nil
            )
        }
        apply(note: segment.note, placement: segment.notePlacement, to: &actions)
        return actions
    }

    private func expandRepeatSegment(_ segment: RepeatSegment) throws -> [ExpandedAtomicAction] {
        guard segment.times > 0 else {
            throw PatternImportFailure.invalidResponse("invalid_repeat_times")
        }
        guard !segment.sequence.isEmpty else {
            throw PatternImportFailure.invalidResponse("empty_repeat_sequence")
        }

        let onePass = try expandSegments(segment.sequence)
        return Array(repeating: onePass, count: segment.times).flatMap { $0 }
    }

    private func expandControlSegment(_ segment: ControlSegment) throws -> [ExpandedAtomicAction] {
        let normalizedInstruction = AtomicAction.normalizedInstruction(segment.instruction)

        switch segment.kind {
        case .turn:
            return [
                ExpandedAtomicAction(
                    type: .custom,
                    instruction: normalizedInstruction ?? "turn",
                    producedStitches: 0,
                    note: segment.note
                )
            ]
        case .skip:
            return [
                ExpandedAtomicAction(
                    type: .skip,
                    instruction: normalizedInstruction ?? "skip",
                    producedStitches: 0,
                    note: segment.note
                )
            ]
        case .custom:
            guard let normalizedInstruction else {
                throw PatternImportFailure.invalidResponse("missing_custom_control_instruction")
            }
            return [
                ExpandedAtomicAction(
                    type: .custom,
                    instruction: normalizedInstruction,
                    producedStitches: 0,
                    note: segment.note
                )
            ]
        }
    }

    private func apply(
        note: String?,
        placement: AtomizedNotePlacement,
        to actions: inout [ExpandedAtomicAction]
    ) {
        guard let normalizedNote = normalizeNote(note), !actions.isEmpty else {
            return
        }

        switch placement {
        case .first:
            actions[0].note = normalizedNote
        case .last:
            actions[actions.count - 1].note = normalizedNote
        case .all:
            for index in actions.indices {
                actions[index].note = normalizedNote
            }
        }
    }

    private func makeAtomicAction(from draft: ExpandedAtomicAction, sequenceIndex: Int) throws -> AtomicAction {
        if draft.type == .custom {
            return AtomicAction(
                type: .custom,
                instruction: AtomicAction.normalizedInstruction(draft.instruction),
                producedStitches: draft.producedStitches,
                note: normalizeNote(draft.note),
                sequenceIndex: sequenceIndex
            )
        }

        return try makeAtomicAction(
            type: draft.type,
            instruction: draft.instruction,
            producedStitches: draft.producedStitches,
            note: draft.note,
            sequenceIndex: sequenceIndex,
            failureBuilder: { type in
                PatternImportFailure.atomizationFailed("atomization_contains_non_action_type:\(type.rawValue)")
            }
        )
    }

    private func makeAtomicAction(
        type: StitchActionType,
        instruction: String?,
        producedStitches: Int?,
        note: String?,
        sequenceIndex: Int,
        failureBuilder: (StitchActionType) -> PatternImportFailure
    ) throws -> AtomicAction {
        guard type.isAtomicActionType else {
            throw failureBuilder(type)
        }

        return AtomicAction(
            type: type,
            instruction: AtomicAction.normalizedInstruction(instruction),
            producedStitches: producedStitches ?? type.defaultProducedStitches,
            note: normalizeNote(note),
            sequenceIndex: sequenceIndex
        )
    }

    private func normalizeNote(_ note: String?) -> String? {
        guard let note else { return nil }
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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

private struct ExpandedAtomicAction: Hashable {
    var type: StitchActionType
    var instruction: String?
    var producedStitches: Int
    var note: String?
}
