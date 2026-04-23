import Foundation

struct AtomizedRoundUpdate: Hashable {
    var reference: RoundReference
    var atomicActions: [AtomicAction]
    /// The number of stitches actually produced by compiling the LLM's IR for this round.
    /// This is NOT the pattern's declared target (see `PatternRound.targetStitchCount` for that).
    /// Consumers should treat this as diagnostic data; it may differ from the declared target
    /// when the LLM failed to atomize the instruction correctly (in which case `warning` will
    /// carry `atomization_target_stitch_count_mismatch`).
    var producedStitchCount: Int
    var warning: String?
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
                rounds: Self.expandOutlinedRounds(part.rounds, logger: logger, context: context)
            )
        }

        let project = CrochetProject(
            title: payload.projectTitle,
            source: source,
            materials: payload.materials,
            confidence: payload.confidence,
            abbreviations: payload.abbreviations,
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
                "roundCount": "\(parts.flatMap(\.rounds).count)",
                "abbreviationCount": "\(payload.abbreviations.count)"
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
                            from: action,
                            sequenceIndex: actionIndex,
                            failureBuilder: { tag in
                                PatternImportFailure.invalidResponse("image_parse_contains_non_action_type:\(tag)")
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
            abbreviations: payload.abbreviations,
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
                  let roundIndex = part.rounds.firstIndex(where: { $0.id == target.roundID }) else {
                throw PatternImportFailure.invalidResponse("missing_round_for_atomization")
            }
            let round = part.rounds[roundIndex]
            let previousStitchCount = roundIndex > 0
                ? part.rounds[roundIndex - 1].targetStitchCount
                : nil

            return AtomizationRoundInput(
                partName: part.name,
                title: round.title,
                rawInstruction: round.rawInstruction,
                summary: round.summary,
                targetStitchCount: round.targetStitchCount,
                previousRoundStitchCount: previousStitchCount,
                abbreviations: project.abbreviations
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
        let response = try await parserClient.parseTextRoundsToIR(
            projectTitle: projectTitle,
            materials: materials,
            rounds: inputs,
            context: context
        )

        guard response.rounds.count == targets.count else {
            throw PatternImportFailure.inconsistentRound("atomized_round_count_mismatch")
        }

        let compiler = CrochetIRCompiler()
        return try zip(zip(targets, inputs), response.rounds).map { entry, payload in
            let (target, input) = entry
            var block = payload
            if block.expectedProducedStitches == nil {
                block.expectedProducedStitches = input.targetStitchCount
            }

            let validation = compiler.validate(block)
            let errors = validation.issues.filter { $0.severity == .error }
            guard errors.isEmpty else {
                let codes = errors.map(\.code).joined(separator: ",")
                throw PatternImportFailure.atomizationFailed("ir_validation_failed:\(codes)")
            }

            let expansion = try compiler.expand(block)
            return AtomizedRoundUpdate(
                reference: target,
                atomicActions: expansion.atomicActions,
                producedStitchCount: expansion.producedStitchCount,
                warning: warningString(from: expansion.warnings)
            )
        }
    }

    private func warningString(from warnings: [CrochetIRExpansionWarning]) -> String? {
        guard !warnings.isEmpty else {
            return nil
        }
        return warnings.map(\.code).joined(separator: ";")
    }

    private func makeAtomicAction(
        from action: ParsedAtomicAction,
        sequenceIndex: Int,
        failureBuilder: (String) -> PatternImportFailure
    ) throws -> AtomicAction {
        if action.semantics != .bookkeeping {
            guard let stitch = action.stitchTag, CrochetStitchCatalog.isValidStitchTag(stitch) else {
                throw failureBuilder(action.stitchTag ?? action.actionTag)
            }
        }
        let defaultProduced = action.stitchTag.map(CrochetStitchCatalog.defaultProducedStitches(for:)) ?? 0
        return AtomicAction(
            semantics: action.semantics,
            actionTag: action.actionTag,
            stitchTag: action.stitchTag,
            instruction: AtomicAction.normalizedInstruction(action.instruction),
            producedStitches: action.producedStitches ?? defaultProduced,
            note: normalizeNote(action.note),
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

    // MARK: - Macro-repeat expansion

    /// Expands macro-repeat sentinels in outlined rounds into individual PatternRound objects.
    /// Normal rounds pass through as-is. Macro-repeat sentinels (with repeatFromTitle,
    /// repeatToTitle, and repeatUntilCount all set) are expanded by cycling through source rounds.
    static func expandOutlinedRounds(
        _ outlinedRounds: [OutlinedPatternRound],
        logger: TraceLogging,
        context: ParseRequestContext
    ) -> [PatternRound] {
        var result: [PatternRound] = []

        for round in outlinedRounds {
            // Range expansion sentinel: a single instruction covers N..M consecutive rows.
            // Must come before the macro-repeat guard so range fields take precedence when
            // both happen to be set; the `repeatFromTitle == nil` check enforces mutual
            // exclusion (LLM is instructed never to set both).
            if let startN = round.rangeStartNumber,
               let endN = round.rangeEndNumber,
               endN >= startN,
               round.repeatFromTitle == nil {
                let count = endN - startN + 1
                let titlePrefix = inferRangeTitlePrefix(from: round.title)
                let groupID = UUID()
                for i in 0..<count {
                    let rowNumber = startN + i
                    result.append(PatternRound(
                        title: "\(titlePrefix) \(rowNumber)",
                        rawInstruction: round.rawInstruction,
                        summary: round.summary,
                        targetStitchCount: round.targetStitchCount,
                        atomizationStatus: .pending,
                        atomizationError: nil,
                        atomicActions: [],
                        macroRepeatSourceIndex: 0,
                        macroRepeatGroupID: groupID
                    ))
                }
                logger.log(LogEvent(
                    timestamp: .now,
                    level: "debug",
                    traceID: context.traceID,
                    parseRequestID: context.parseRequestID,
                    projectID: nil,
                    sourceType: nil,
                    stage: "range_expansion",
                    decision: "expanded",
                    reason: "range_expanded",
                    durationMS: nil,
                    metadata: [
                        "rangeStartNumber": "\(startN)",
                        "rangeEndNumber": "\(endN)",
                        "expandedRoundCount": "\(count)"
                    ]
                ))
                continue
            }

            guard let fromTitle = round.repeatFromTitle,
                  let toTitle = round.repeatToTitle,
                  let untilCount = round.repeatUntilCount else {
                // Normal round — pass through.
                result.append(PatternRound(
                    title: round.title,
                    rawInstruction: round.rawInstruction,
                    summary: round.summary,
                    targetStitchCount: round.targetStitchCount,
                    atomizationStatus: .pending,
                    atomizationError: nil,
                    atomicActions: []
                ))
                continue
            }

            // Macro-repeat sentinel — find source rounds and expand.
            let sourceRounds = findSourceRounds(
                from: fromTitle,
                to: toTitle,
                in: outlinedRounds
            )

            guard !sourceRounds.isEmpty else {
                // Source rounds not found — graceful degradation.
                logger.log(LogEvent(
                    timestamp: .now,
                    level: "warning",
                    traceID: context.traceID,
                    parseRequestID: context.parseRequestID,
                    projectID: nil,
                    sourceType: nil,
                    stage: "macro_repeat_expansion",
                    decision: "fallback",
                    reason: "source_rounds_not_found",
                    durationMS: nil,
                    metadata: [
                        "repeatFromTitle": fromTitle,
                        "repeatToTitle": toTitle
                    ]
                ))
                result.append(PatternRound(
                    title: round.title,
                    rawInstruction: round.rawInstruction,
                    summary: round.summary,
                    targetStitchCount: round.targetStitchCount,
                    atomizationStatus: .pending,
                    atomizationError: nil,
                    atomicActions: []
                ))
                continue
            }

            // Use repeatAfterRow (LLM-provided) for correct row numbering;
            // fall back to result.count when the field is absent.
            let afterRow = round.repeatAfterRow ?? result.count
            let needed = untilCount - afterRow

            guard needed > 0 else {
                // Already at or past target — skip expansion.
                logger.log(LogEvent(
                    timestamp: .now,
                    level: "warning",
                    traceID: context.traceID,
                    parseRequestID: context.parseRequestID,
                    projectID: nil,
                    sourceType: nil,
                    stage: "macro_repeat_expansion",
                    decision: "skip",
                    reason: "already_past_target",
                    durationMS: nil,
                    metadata: [
                        "afterRow": "\(afterRow)",
                        "repeatUntilCount": "\(untilCount)"
                    ]
                ))
                result.append(PatternRound(
                    title: round.title,
                    rawInstruction: round.rawInstruction,
                    summary: round.summary,
                    targetStitchCount: round.targetStitchCount,
                    atomizationStatus: .pending,
                    atomizationError: nil,
                    atomicActions: []
                ))
                continue
            }

            let cycleLength = sourceRounds.count
            let groupID = UUID()
            for i in 0..<needed {
                let sourceIndex = i % cycleLength
                let source = sourceRounds[sourceIndex]
                let newRowNumber = afterRow + i + 1
                let newTitle = replaceTrailingNumber(
                    in: source.title,
                    with: newRowNumber
                )
                result.append(PatternRound(
                    title: newTitle,
                    rawInstruction: source.rawInstruction,
                    summary: source.summary,
                    targetStitchCount: source.targetStitchCount,
                    atomizationStatus: .pending,
                    atomizationError: nil,
                    atomicActions: [],
                    macroRepeatSourceIndex: sourceIndex,
                    macroRepeatGroupID: groupID
                ))
            }

            logger.log(LogEvent(
                timestamp: .now,
                level: "debug",
                traceID: context.traceID,
                parseRequestID: context.parseRequestID,
                projectID: nil,
                sourceType: nil,
                stage: "macro_repeat_expansion",
                decision: "expanded",
                reason: "macro_repeat_expanded",
                durationMS: nil,
                metadata: [
                    "sourceRoundCount": "\(cycleLength)",
                    "expandedRoundCount": "\(needed)",
                    "totalRoundsAfterExpansion": "\(result.count)"
                ]
            ))
        }

        return result
    }

    /// Finds the contiguous subsequence of outlined rounds whose titles match
    /// the range [fromTitle...toTitle].
    static func findSourceRounds(
        from fromTitle: String,
        to toTitle: String,
        in rounds: [OutlinedPatternRound]
    ) -> [OutlinedPatternRound] {
        guard let startIndex = rounds.firstIndex(where: { $0.title == fromTitle }) else {
            return []
        }
        guard let endIndex = rounds.firstIndex(where: { $0.title == toTitle }),
              endIndex >= startIndex else {
            return []
        }
        return Array(rounds[startIndex...endIndex])
    }

    /// Replaces the last contiguous sequence of digits in the title with a new number.
    /// e.g. "Row 6" → "Row 14", "Round 13" → "Round 21".
    /// If no digits are found, appends " {number}".
    static func replaceTrailingNumber(
        in title: String,
        with newNumber: Int
    ) -> String {
        guard let lastDigitIndex = title.lastIndex(where: { $0.isNumber }) else {
            return "\(title) \(newNumber)"
        }

        // Walk backwards from the last digit to find the start of the contiguous digit sequence.
        var start = lastDigitIndex
        while start > title.startIndex {
            let prev = title.index(before: start)
            guard title[prev].isNumber else { break }
            start = prev
        }

        let end = title.index(after: lastDigitIndex)
        return String(title[title.startIndex..<start]) + "\(newNumber)" + String(title[end..<title.endIndex])
    }

    /// Infers the single-row title prefix from a range sentinel title.
    /// "Rows 2-109" → "Row", "Rounds 9-10" → "Round". Falls back to "Row".
    static func inferRangeTitlePrefix(from title: String) -> String {
        let lower = title.lowercased()
        if lower.hasPrefix("rounds") || lower.hasPrefix("round") { return "Round" }
        if lower.hasPrefix("rows") || lower.hasPrefix("row") { return "Row" }
        return "Row"
    }
}

