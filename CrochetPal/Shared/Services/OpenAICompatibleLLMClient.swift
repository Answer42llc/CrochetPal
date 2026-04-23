import Foundation

protocol PatternLLMParsing {
    func parseTextPatternOutline(
        extractedText: String,
        titleHint: String?,
        context: ParseRequestContext
    ) async throws -> PatternOutlineResponse

    func parseTextRoundsToIR(
        projectTitle: String,
        materials: [String],
        rounds: [AtomizationRoundInput],
        context: ParseRequestContext
    ) async throws -> CrochetIRAtomizationResponse

    func parseImagePattern(
        imageData: Data,
        mimeType: String,
        fileName: String,
        context: ParseRequestContext
    ) async throws -> PatternParseResponse
}

protocol AtomizationMatchEvaluating {
    func evaluateAtomizedRoundMatch(
        input: AtomizationMatchEvaluationInput,
        context: ParseRequestContext
    ) async throws -> AtomizationMatchEvaluation
}

struct AtomizationMatchSubagent {
    private let evaluator: AtomizationMatchEvaluating

    init(evaluator: AtomizationMatchEvaluating) {
        self.evaluator = evaluator
    }

    func evaluate(
        input: AtomizationMatchEvaluationInput,
        context: ParseRequestContext
    ) async throws -> AtomizationMatchEvaluation {
        try await evaluator.evaluateAtomizedRoundMatch(input: input, context: context)
    }
}

final class OpenAICompatibleLLMClient: PatternLLMParsing, AtomizationMatchEvaluating {
    private typealias JSONObject = [String: Any]

    private let configuration: RuntimeConfiguration
    private let session: URLSession
    private let logger: TraceLogging

    init(configuration: RuntimeConfiguration, session: URLSession = .shared, logger: TraceLogging) {
        self.configuration = configuration
        self.session = session
        self.logger = logger
    }

    func parseTextPatternOutline(
        extractedText: String,
        titleHint: String?,
        context: ParseRequestContext
    ) async throws -> PatternOutlineResponse {
        let prompt = PromptFactory.textOutlinePrompt(extractedText: extractedText, titleHint: titleHint)
        let messages: [[String: Any]] = [
            ["role": "system", "content": PromptFactory.textOutlineSystemPrompt()],
            ["role": "user", "content": prompt]
        ]
        return try await sendChatCompletion(
            modelID: configuration.textModelID,
            messagePayload: messages,
            context: context,
            modelKind: "text_outline_parser",
            responseFormat: PromptFactory.outlineResponseFormat(),
            providerPayload: textProviderPayload(for: configuration.textModelID),
            temperature: 0
        )
    }

    func parseTextRoundsToIR(
        projectTitle: String,
        materials: [String],
        rounds: [AtomizationRoundInput],
        context: ParseRequestContext
    ) async throws -> CrochetIRAtomizationResponse {
        let prompt = PromptFactory.roundIRAtomizationPrompt(
            projectTitle: projectTitle,
            materials: materials,
            rounds: rounds
        )
        let messages: [[String: Any]] = [
            ["role": "system", "content": PromptFactory.roundIRAtomizationSystemPrompt()],
            ["role": "user", "content": prompt]
        ]
        return try await sendChatCompletion(
            modelID: configuration.atomizationModelID,
            messagePayload: messages,
            context: context,
            modelKind: "round_ir_parser",
            responseFormat: PromptFactory.irAtomizationResponseFormat(),
            providerPayload: textProviderPayload(for: configuration.atomizationModelID),
            temperature: 0,
            repairModelID: configuration.atomizationModelID,
            repairProviderPayload: textProviderPayload(for: configuration.atomizationModelID)
        )
    }

    func parseImagePattern(
        imageData: Data,
        mimeType: String,
        fileName: String,
        context: ParseRequestContext
    ) async throws -> PatternParseResponse {
        let base64 = imageData.base64EncodedString()
        let prompt = PromptFactory.imagePrompt(fileName: fileName)
        let messages: [[String: Any]] = [
            ["role": "system", "content": PromptFactory.imageSystemPrompt()],
            ["role": "user", "content": [
                ["type": "text", "text": prompt],
                ["type": "image_url", "image_url": ["url": "data:\(mimeType);base64,\(base64)"]]
            ]]
        ]

        return try await sendChatCompletion(
            modelID: configuration.visionModelID,
            messagePayload: messages,
            context: context,
            modelKind: "vision_parser",
            responseFormat: PromptFactory.imageResponseFormat(),
            providerPayload: [
                "require_parameters": true,
                "allow_fallbacks": false
            ],
            temperature: 0
        )
    }

    func evaluateAtomizedRoundMatch(
        input: AtomizationMatchEvaluationInput,
        context: ParseRequestContext
    ) async throws -> AtomizationMatchEvaluation {
        let prompt = PromptFactory.atomizationMatchEvaluationPrompt(input: input)
        let messages: [[String: Any]] = [
            ["role": "system", "content": PromptFactory.atomizationMatchEvaluationSystemPrompt()],
            ["role": "user", "content": prompt]
        ]

        let evaluation: AtomizationMatchEvaluation = try await sendChatCompletion(
            modelID: configuration.textModelID,
            messagePayload: messages,
            context: context,
            modelKind: "atomization_match_evaluator",
            responseFormat: PromptFactory.atomizationMatchEvaluationResponseFormat(),
            providerPayload: textProviderPayload(for: configuration.textModelID),
            temperature: 0,
            repairModelID: configuration.textModelID,
            repairProviderPayload: textProviderPayload(for: configuration.textModelID)
        )

        return try await repairAtomizationMatchEvaluationIfNeeded(
            evaluation,
            input: input,
            context: context
        )
    }

    private func repairAtomizationMatchEvaluationIfNeeded(
        _ evaluation: AtomizationMatchEvaluation,
        input: AtomizationMatchEvaluationInput,
        context: ParseRequestContext
    ) async throws -> AtomizationMatchEvaluation {
        guard let consistencyProblems = atomizationMatchConsistencyProblems(
            for: evaluation,
            input: input
        ) else {
            return evaluation
        }

        logger.log(LogEvent(
            timestamp: .now,
            level: "warning",
            traceID: context.traceID,
            parseRequestID: context.parseRequestID,
            projectID: nil,
            sourceType: context.sourceType,
            stage: "llm_repair",
            decision: "retry",
            reason: "atomization_match_inconsistent",
            durationMS: nil,
            metadata: [
                "consistencyProblems": consistencyProblems.joined(separator: " | "),
                "roundTitle": evaluation.roundTitle
            ]
        ))

        let repairMessages: [[String: Any]] = [
            ["role": "system", "content": PromptFactory.atomizationMatchEvaluationRepairSystemPrompt()],
            [
                "role": "user",
                "content": PromptFactory.atomizationMatchEvaluationRepairPrompt(
                    input: input,
                    invalidEvaluation: evaluation,
                    consistencyProblems: consistencyProblems
                )
            ]
        ]

        let repaired: AtomizationMatchEvaluation = try await sendChatCompletion(
            modelID: configuration.textModelID,
            messagePayload: repairMessages,
            context: context,
            modelKind: "atomization_match_evaluator_consistency_repair",
            responseFormat: PromptFactory.atomizationMatchEvaluationResponseFormat(),
            providerPayload: textProviderPayload(for: configuration.textModelID),
            temperature: 0,
            allowsRepair: false
        )

        return canonicalizeAtomizationMatchEvaluation(
            repaired,
            input: input
        )
    }

    private func atomizationMatchConsistencyProblems(
        for evaluation: AtomizationMatchEvaluation,
        input: AtomizationMatchEvaluationInput
    ) -> [String]? {
        var problems: [String] = []
        let hasEvidence = !evaluation.issueCodes.isEmpty
            || !evaluation.missingElements.isEmpty
            || !evaluation.extraElements.isEmpty
        let hasValidationFailure = input.validationIssues.contains { $0.severity == .error }
            || input.expansionFailure != nil

        switch evaluation.verdict {
        case .exactMatch, .normalizedMatch:
            if hasValidationFailure {
                problems.append("passing verdict cannot coexist with validation errors or expansion failure")
            }
            if hasEvidence {
                problems.append("passing verdict must not include issueCodes, missingElements, or extraElements")
            }
        case .partialMatch, .mismatch:
            if !hasEvidence {
                problems.append("failing verdict must include at least one issue code, missing element, or extra element")
            }
        case .notActionable:
            if hasEvidence {
                problems.append("not_actionable verdict must not include issueCodes, missingElements, or extraElements")
            }
        }

        return problems.isEmpty ? nil : problems
    }

    private func canonicalizeAtomizationMatchEvaluation(
        _ evaluation: AtomizationMatchEvaluation,
        input: AtomizationMatchEvaluationInput
    ) -> AtomizationMatchEvaluation {
        var canonical = evaluation
        canonical.roundTitle = input.roundTitle
        canonical.rawInstruction = input.rawInstruction
        canonical.confidence = min(1, max(0, canonical.confidence))

        let hasValidationFailure = input.validationIssues.contains { $0.severity == .error }
            || input.expansionFailure != nil
        let hasEvidence = !canonical.issueCodes.isEmpty
            || !canonical.missingElements.isEmpty
            || !canonical.extraElements.isEmpty

        switch canonical.verdict {
        case .exactMatch, .normalizedMatch:
            if hasValidationFailure || hasEvidence {
                canonical.verdict = .partialMatch
            }
        case .partialMatch, .mismatch:
            if !hasEvidence {
                if input.expansionFailure != nil {
                    canonical.issueCodes = [.expansionFailure]
                } else if input.validationIssues.contains(where: { $0.severity == .error }) {
                    canonical.issueCodes = [.validationError]
                } else {
                    canonical.issueCodes = [.ambiguousSource]
                }
            }
        case .notActionable:
            canonical.issueCodes = []
            canonical.missingElements = []
            canonical.extraElements = []
        }

        return canonical
    }

    private func sendChatCompletion<Response: Decodable>(
        modelID: String,
        messagePayload: [[String: Any]],
        context: ParseRequestContext,
        modelKind: String,
        responseFormat: JSONObject,
        providerPayload: JSONObject? = nil,
        temperature: Double = 0.1,
        allowsRepair: Bool = true,
        repairModelID: String? = nil,
        repairProviderPayload: JSONObject? = nil
    ) async throws -> Response {
        let endpoint = configuration.baseURL.appending(path: "chat/completions")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")

        var body: JSONObject = [
            "model": modelID,
            "temperature": temperature,
            "messages": messagePayload,
            "response_format": responseFormat
        ]
        if usesOpenRouterExtensions() {
            body["plugins"] = responseHealingPlugins()
        }
        if let providerPayload {
            body["provider"] = providerPayload
        }
        let requestBody = try JSONSerialization.data(withJSONObject: body)
        request.httpBody = requestBody

        logger.log(LogEvent(
            timestamp: .now,
            level: "debug",
            traceID: context.traceID,
            parseRequestID: context.parseRequestID,
            projectID: nil,
            sourceType: context.sourceType,
            stage: "llm_request_payload",
            decision: modelKind,
            reason: "prepared_request_payload",
            durationMS: nil,
            metadata: [
                "modelID": modelID,
                "requestJSON": serializeForLogging(sanitizedForLogging(body))
            ]
        ))

        let started = Date()
        let (data, response) = try await session.data(for: request)
        let duration = Int(Date().timeIntervalSince(started) * 1000)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw PatternImportFailure.invalidResponse("missing_http_response")
        }
        guard 200..<300 ~= httpResponse.statusCode else {
            logger.log(LogEvent(
                timestamp: .now,
                level: "error",
                traceID: context.traceID,
                parseRequestID: context.parseRequestID,
                projectID: nil,
                sourceType: context.sourceType,
                stage: "llm_request",
                decision: "failure",
                reason: "http_error",
                durationMS: duration,
                metadata: [
                    "modelID": modelID,
                    "statusCode": "\(httpResponse.statusCode)",
                    "responseEnvelopeJSON": serializeResponseDataForLogging(data)
                ]
            ))
            throw makeHTTPFailure(statusCode: httpResponse.statusCode, data: data)
        }

        logger.log(LogEvent(
            timestamp: .now,
            level: "debug",
            traceID: context.traceID,
            parseRequestID: context.parseRequestID,
            projectID: nil,
            sourceType: context.sourceType,
            stage: "llm_request",
            decision: modelKind,
            reason: "received_response",
            durationMS: duration,
            metadata: [
                "modelID": modelID,
                "statusCode": "\(httpResponse.statusCode)",
                "responseBytes": "\(data.count)",
                "responseFormat": (responseFormat["type"] as? String) ?? "unknown"
            ]
        ))

        guard let content = try extractContent(from: data) else {
            throw PatternImportFailure.invalidResponse("missing_message_content")
        }

        logger.log(LogEvent(
            timestamp: .now,
            level: "debug",
            traceID: context.traceID,
            parseRequestID: context.parseRequestID,
            projectID: nil,
            sourceType: context.sourceType,
            stage: "llm_response_payload",
            decision: modelKind,
            reason: "received_response_payload",
            durationMS: duration,
            metadata: [
                "modelID": modelID,
                "responseEnvelopeJSON": serializeResponseDataForLogging(data),
                "assistantContent": content
            ]
        ))

        do {
            return try decodeResponse(from: content)
        } catch {
            if allowsRepair {
                logger.log(LogEvent(
                    timestamp: .now,
                    level: "warning",
                    traceID: context.traceID,
                    parseRequestID: context.parseRequestID,
                    projectID: nil,
                    sourceType: context.sourceType,
                    stage: "llm_repair",
                    decision: "retry",
                    reason: "json_decode_failed",
                    durationMS: nil,
                    metadata: [
                        "modelID": modelID,
                        "contentPreview": String(content.prefix(500))
                    ]
                ))

                do {
                    return try await repairMalformedResponse(
                        content,
                        originalModelID: modelID,
                        repairModelID: repairModelID ?? configuration.textModelID,
                        context: context,
                        responseFormat: responseFormat,
                        providerPayload: repairProviderPayload ?? textProviderPayload(for: repairModelID ?? configuration.textModelID)
                    )
                } catch {
                    logger.log(LogEvent(
                        timestamp: .now,
                        level: "error",
                        traceID: context.traceID,
                        parseRequestID: context.parseRequestID,
                        projectID: nil,
                        sourceType: context.sourceType,
                        stage: "llm_repair",
                        decision: "failure",
                        reason: "json_repair_failed",
                        durationMS: nil,
                        metadata: [
                            "modelID": modelID,
                            "error": error.localizedDescription
                        ]
                    ))
                }
            }

            logger.log(LogEvent(
                timestamp: .now,
                level: "error",
                traceID: context.traceID,
                parseRequestID: context.parseRequestID,
                projectID: nil,
                sourceType: context.sourceType,
                stage: "llm_decode",
                decision: "failure",
                reason: "json_decode_failed",
                durationMS: nil,
                metadata: [
                    "modelID": modelID,
                    "contentPreview": String(content.prefix(500))
                ]
            ))
            throw PatternImportFailure.invalidResponse("json_decode_failed")
        }
    }

    private func repairMalformedResponse<Response: Decodable>(
        _ invalidContent: String,
        originalModelID: String,
        repairModelID: String,
        context: ParseRequestContext,
        responseFormat: JSONObject,
        providerPayload: JSONObject? = nil
    ) async throws -> Response {
        let messages: [[String: Any]] = [
            ["role": "system", "content": PromptFactory.repairSystemPrompt()],
            ["role": "user", "content": PromptFactory.repairPrompt(
                invalidContent: invalidContent,
                originalModelID: originalModelID
            )]
        ]

        return try await sendChatCompletion(
            modelID: repairModelID,
            messagePayload: messages,
            context: context,
            modelKind: "json_repair",
            responseFormat: responseFormat,
            providerPayload: providerPayload,
            temperature: 0,
            allowsRepair: false
        )
    }

    private func textProviderPayload(for modelID: String) -> JSONObject? {
//        guard modelID == "deepseek/deepseek-v3.2" else {
//            return nil
//        }
//
//        return [
//            "require_parameters": true,
//            "allow_fallbacks": false,
//            "order": ["atlas-cloud/fp8", "siliconflow/fp8"]
//        ]
        return nil
    }

    private func responseHealingPlugins() -> [JSONObject] {
        [["id": "response-healing"]]
    }

    private func usesOpenRouterExtensions() -> Bool {
        let host = configuration.baseURL.host?.lowercased() ?? ""
        let path = configuration.baseURL.path.lowercased()
        return host.contains("openrouter.ai") || path.contains("/openrouter/")
    }

    private func sanitizedForLogging(_ value: Any) -> Any {
        if let dictionary = value as? [String: Any] {
            return dictionary.reduce(into: [String: Any]()) { partialResult, item in
                let (key, rawValue) = item
                if key == "url", let url = rawValue as? String, url.hasPrefix("data:") {
                    partialResult[key] = "[omitted data URL]"
                } else {
                    partialResult[key] = sanitizedForLogging(rawValue)
                }
            }
        }

        if let array = value as? [Any] {
            return array.map(sanitizedForLogging)
        }

        return value
    }

    private func serializeForLogging(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return String(describing: value)
        }
        return string
    }

    private func serializeResponseDataForLogging(_ data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) {
            return serializeForLogging(object)
        }

        return String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func extractContent(from data: Data) throws -> String? {
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let choices = object?["choices"] as? [[String: Any]]
        let message = choices?.first?["message"] as? [String: Any]

        if let content = message?["content"] as? String {
            return content
        }

        if let parts = message?["content"] as? [[String: Any]] {
            return parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }

        return nil
    }

    private func decodeResponse<Response: Decodable>(from text: String) throws -> Response {
        let payload = extractJSONObject(from: text)
        let data = Data(payload.utf8)
        let decoder = JSONDecoder()
        return try decoder.decode(Response.self, from: data)
    }

    private func makeHTTPFailure(statusCode: Int, data: Data) -> PatternImportFailure {
        PatternImportFailure.fetchFailed(
            statusCode: statusCode,
            details: extractErrorMessage(from: data)
        )
    }

    private func extractErrorMessage(from data: Data) -> String? {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let message = extractErrorMessage(fromJSONObject: object) {
            return message
        }

        let rawText = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return rawText.isEmpty ? nil : rawText
    }

    private func extractErrorMessage(fromJSONObject object: [String: Any]) -> String? {
        if let errorObject = object["error"] as? [String: Any] {
            let metadata = errorObject["metadata"] as? [String: Any]
            let providerName = normalizedMessage(metadata?["provider_name"] as? String)
            let providerRaw = normalizedMessage(metadata?["raw"] as? String)
            let nestedProviderMessage = providerRaw.flatMap(extractNestedErrorMessage(fromRawPayload:))
            let outerMessage = normalizedMessage(errorObject["message"] as? String)

            let preferredMessage: String?
            if let nestedProviderMessage {
                preferredMessage = nestedProviderMessage
            } else if outerMessage == "Provider returned error" {
                preferredMessage = nil
            } else {
                preferredMessage = outerMessage
            }

            switch (providerName, preferredMessage) {
            case let (providerName?, preferredMessage?):
                return "\(providerName): \(preferredMessage)"
            case let (_, preferredMessage?):
                return preferredMessage
            case let (providerName?, _):
                return providerName
            default:
                break
            }
        }

        if let message = normalizedMessage(object["message"] as? String) {
            return message
        }

        return nil
    }

    private func extractNestedErrorMessage(fromRawPayload rawPayload: String) -> String? {
        let trimmed = rawPayload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        if let data = trimmed.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let nestedError = object["error"] as? [String: Any],
           let nestedMessage = normalizedMessage(nestedError["message"] as? String) {
            return nestedMessage
        }

        return trimmed
    }

    private func normalizedMessage(_ value: String?) -> String? {
        guard let value else {
            return nil
        }

        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    private func extractJSONObject(from text: String) -> String {
        guard let first = text.firstIndex(of: "{"), let last = text.lastIndex(of: "}") else {
            return text
        }
        return String(text[first...last])
    }
}

enum PromptFactory {
    private static let outlineExampleJSON = """
    {
      "projectTitle": "Mouse Cat Toy",
      "materials": ["3.75 mm crochet hook", "Cotton yarn"],
      "confidence": 0.91,
      "abbreviations": [
        { "term": "sc", "definition": "single crochet" },
        { "term": "ch", "definition": "chain" },
        { "term": "cs", "definition": "cap stitch (pull up loop, yarn over, pull through first loop only)" }
      ],
      "parts": [
        {
          "name": "Body",
          "rounds": [
            {
              "title": "Round 1",
              "rawInstruction": "In a MR, sc 6. (6)",
              "summary": "Create a magic ring and work six single crochets into it.",
              "targetStitchCount": 6,
              "repeatFromTitle": null,
              "repeatToTitle": null,
              "repeatUntilCount": null,
              "repeatAfterRow": null,
              "rangeStartNumber": null,
              "rangeEndNumber": null
            },
            {
              "title": "Rounds 9-10",
              "rawInstruction": "sc around. (18)",
              "summary": "Work a single crochet in every stitch around, for two rounds.",
              "targetStitchCount": 18,
              "repeatFromTitle": null,
              "repeatToTitle": null,
              "repeatUntilCount": null,
              "repeatAfterRow": null,
              "rangeStartNumber": 9,
              "rangeEndNumber": 10
            },
            {
              "title": "Repeat Rounds 2-5",
              "rawInstruction": "Repeat Rounds 2-5 until you have 20 rounds total.",
              "summary": "Cycle through rounds 2-5 until the body reaches 20 rounds.",
              "targetStitchCount": null,
              "repeatFromTitle": "Round 2",
              "repeatToTitle": "Round 5",
              "repeatUntilCount": 20,
              "repeatAfterRow": 5,
              "rangeStartNumber": null,
              "rangeEndNumber": null
            },
            {
              "title": "Add stuffing",
              "rawInstruction": "Add stuffing.",
              "summary": "Add stuffing to the body before closing.",
              "targetStitchCount": null,
              "repeatFromTitle": null,
              "repeatToTitle": null,
              "repeatUntilCount": null,
              "repeatAfterRow": null,
              "rangeStartNumber": null,
              "rangeEndNumber": null
            }
          ]
        }
      ]
    }
    """

    private static let irAtomizationExampleJSON = """
    {
      "rounds": [
        {
          "title": "Squaring",
          "sourceText": "[dc inc, 8hdc, dc inc, ch3] repeat 3 times, omit the final ch3. Instead, work ch1, then 1hdc into the top of the first ch3.",
          "expectedProducedStitches": 37,
          "body": {
            "statements": [
              {
                "kind": "repeat",
                "sourceText": "[dc inc, 8hdc, dc inc, ch3] repeat 3 times, omit the final ch3",
                "operation": null,
                "repeat": {
                  "times": 2,
                  "sourceRepeatCount": 3,
                  "normalizationNote": "Original repeat count was 3, but the final iteration differs. Normalized to a homogeneous repeat of 2 plus the final iteration flattened below.",
                  "body": {
                    "sourceText": "[dc inc, 8hdc, dc inc, ch3]",
                    "normalizationNote": null,
                    "statements": [
                      { "kind": "operation", "sourceText": "dc inc", "operation": { "semantics": "increase", "actionTag": "increase", "stitch": "dc", "count": 1, "instruction": null, "target": null, "note": "dc inc", "notePlacement": "all", "producedStitches": 2 }, "repeat": null, "conditional": null, "note": null },
                      { "kind": "operation", "sourceText": "8hdc", "operation": { "semantics": "stitchProducing", "actionTag": "hdc", "stitch": "hdc", "count": 8, "instruction": null, "target": null, "note": null, "notePlacement": "first", "producedStitches": null }, "repeat": null, "conditional": null, "note": null },
                      { "kind": "operation", "sourceText": "dc inc", "operation": { "semantics": "increase", "actionTag": "increase", "stitch": "dc", "count": 1, "instruction": null, "target": null, "note": "dc inc", "notePlacement": "all", "producedStitches": 2 }, "repeat": null, "conditional": null, "note": null },
                      { "kind": "operation", "sourceText": "ch3", "operation": { "semantics": "stitchProducing", "actionTag": "ch", "stitch": "ch", "count": 3, "instruction": null, "target": null, "note": null, "notePlacement": "first", "producedStitches": null }, "repeat": null, "conditional": null, "note": null }
                    ]
                  }
                },
                "conditional": null,
                "note": null
              },
              { "kind": "operation", "sourceText": "dc inc", "operation": { "semantics": "increase", "actionTag": "increase", "stitch": "dc", "count": 1, "instruction": null, "target": null, "note": "dc inc", "notePlacement": "all", "producedStitches": 2 }, "repeat": null, "conditional": null, "note": null },
              { "kind": "operation", "sourceText": "8hdc", "operation": { "semantics": "stitchProducing", "actionTag": "hdc", "stitch": "hdc", "count": 8, "instruction": null, "target": null, "note": null, "notePlacement": "first", "producedStitches": null }, "repeat": null, "conditional": null, "note": null },
              { "kind": "operation", "sourceText": "dc inc", "operation": { "semantics": "increase", "actionTag": "increase", "stitch": "dc", "count": 1, "instruction": null, "target": null, "note": "dc inc", "notePlacement": "all", "producedStitches": 2 }, "repeat": null, "conditional": null, "note": null },
              { "kind": "operation", "sourceText": "ch1", "operation": { "semantics": "stitchProducing", "actionTag": "ch", "stitch": "ch", "count": 1, "instruction": null, "target": null, "note": null, "notePlacement": "first", "producedStitches": null }, "repeat": null, "conditional": null, "note": null },
              { "kind": "operation", "sourceText": "1hdc into the top of the first ch3", "operation": { "semantics": "stitchProducing", "actionTag": "hdc", "stitch": "hdc", "count": 1, "instruction": null, "target": "top of the first ch3", "note": null, "notePlacement": "first", "producedStitches": null }, "repeat": null, "conditional": null, "note": null }
            ],
            "sourceText": null,
            "normalizationNote": null
          }
        },
        {
          "title": "Round 3",
          "sourceText": "sc around. (9)",
          "expectedProducedStitches": 9,
          "body": {
            "statements": [
              { "kind": "operation", "sourceText": "sc around", "operation": { "semantics": "stitchProducing", "actionTag": "sc", "stitch": "sc", "count": 9, "instruction": null, "target": null, "note": null, "notePlacement": "first", "producedStitches": null }, "repeat": null, "conditional": null, "note": null }
            ],
            "sourceText": null,
            "normalizationNote": null
          }
        }
      ]
    }
    """

    private static let imageExampleJSON = """
    {
      "projectTitle": "Mouse Cat Toy",
      "materials": ["3.75 mm crochet hook"],
      "confidence": 0.91,
      "abbreviations": [],
      "parts": [
        {
          "name": "Body",
          "rounds": [
            {
              "title": "Round 1",
              "rawInstruction": "In a MR, sc 6. (6)",
              "summary": "Create a magic ring and work six single crochets.",
              "targetStitchCount": 6,
              "atomicActions": [
                { "semantics": "stitchProducing", "actionTag": "mr", "stitchTag": "mr", "instruction": "mr", "producedStitches": 0, "note": null },
                { "semantics": "stitchProducing", "actionTag": "sc", "stitchTag": "sc", "instruction": "sc", "producedStitches": 1, "note": null }
              ]
            }
          ]
        }
      ]
    }
    """

    private static let atomizationMatchEvaluationExampleJSON = """
    {
      "roundTitle": "Round 3",
      "rawInstruction": "sc around. (9)",
      "verdict": "normalized_match",
      "confidence": 0.96,
      "issueCodes": [],
      "missingElements": [],
      "extraElements": [],
      "rationale": "The atomic actions preserve the instruction semantically by expanding 'sc around' into nine single crochets."
    }
    """

    static func textOutlineSystemPrompt() -> String {
        """
        You are a crochet master. Convert the provided crochet pattern text into one valid JSON object.
        Extract:
        - projectTitle: the thing the pattern makes, not the blog post title
        - materials
        - confidence
        - abbreviations: pattern-author-defined terminology. If the pattern contains an "Abbreviations" section (or similar — "Key", "Terms", "Stitches used") listing term-to-definition mappings (e.g., "cs = cap stitch (pull up loop, yarn over…)"), capture each entry as {term, definition}. Include both pattern-specific invented abbreviations (like "cs") AND standard ones the author chose to spell out. If no such section exists, return an empty array.
        - parts and rounds

        Rules:
        - Keep only actionable crochet content.
        - Preserve part and round order from the source.
        - Preserve part names such as Body, Head, Eyes, Ears when present.
        - Range expansion: When a single instruction covers multiple consecutive rows or rounds with identical work (e.g., "Rows 2-109: Ch 1, sc in first 3 sts. Hdc in next st. dc in next 8 sts. Hdc in next st. sc in last 3 sts.", "Rounds 9-10: sc around. (18)", "Rounds 15-17: sc around. (24)"), emit exactly ONE range sentinel round object. Do NOT expand it yourself into one object per row/round — the app handles the expansion locally. Set its title to the original range label (e.g., "Rows 2-109" or "Rounds 9-10"); set rawInstruction to the single-row form with the range prefix stripped (e.g., "Ch 1, sc in first 3 sts. Hdc in next st. dc in next 8 sts. Hdc in next st. sc in last 3 sts." — never keep the "Rows N-M:" prefix); set summary to a brief description; set targetStitchCount from the explicit parenthesized count if present, otherwise null; set rangeStartNumber to the start number (e.g., 2 or 9); set rangeEndNumber to the end number (e.g., 109 or 10); set repeatFromTitle, repeatToTitle, repeatUntilCount, and repeatAfterRow to null. Emitting individual per-row objects for a "Rows N-M: <work>" instruction is incorrect — always use a single sentinel with rangeStartNumber and rangeEndNumber.
        - Macro-repeat: When the pattern says to repeat a sequence of previously defined rows/rounds until a total row/round count is reached (e.g., "Repeat Rows 6-13 until you have a total of 118 rows", "Rep rounds 2-5 for a total of 40 rounds"), emit exactly ONE placeholder round object. Set its title to a descriptive label (e.g., "Repeat Rows 6-13"), rawInstruction to the original verbatim text, summary to a brief description, targetStitchCount to null, repeatFromTitle to the title of the first round in the repeating cycle (e.g., "Row 6"), repeatToTitle to the title of the last round in the repeating cycle (e.g., "Row 13"), repeatUntilCount to the total number of rows/rounds the pattern wants (e.g., 118), repeatAfterRow to the row/round number of the last numbered row that appears before this macro-repeat instruction in the pattern (e.g., if the repeat comes right after Row 13, set to 13; if rows 1-14 exist before the repeat, set to 14; non-stitch instruction rounds like "Foundation Chain" or "Add stuffing" do not count), and both rangeStartNumber and rangeEndNumber to null. Do NOT expand the macro-repeat into individual rounds yourself — the app will handle the expansion. Distinction from range expansion: range expansion is for one instruction covering multiple consecutive rows/rounds with identical work (use rangeStartNumber/rangeEndNumber); macro-repeat is for re-cycling through a previously defined sequence of rounds to reach a total count (use repeatFromTitle/repeatToTitle/repeatUntilCount). The two field sets are mutually exclusive — at most one set may be non-null on any given round object.
        - If additional instructions follow the macro-repeat or range sentinel in the same sentence or paragraph (such as "Then do one more row of sc" or "Weave in ends"), capture each such instruction as its own separate round object placed after the sentinel, following the existing rule for non-stitch instructions.
        - For all normal rounds and non-stitch instruction rounds, set repeatFromTitle, repeatToTitle, repeatUntilCount, repeatAfterRow, rangeStartNumber, and rangeEndNumber to null.
        - Do not generate atomicActions in this stage.
        - targetStitchCount must only be set when the pattern text explicitly states a stitch count for that round (e.g., a number in parentheses such as "(18)" or "(6 sts)" at the end of the instruction). Do NOT calculate or infer targetStitchCount from the stitch operations. If no explicit stitch count appears in the pattern text for that round, set targetStitchCount to null.
        - Non-stitch instructions that appear between rounds, before the first round, or after the last round (such as "Add stuffing", "Finish off and sew closed", "Add safety eyes", "Weave in ends") are important crafting steps. Capture each such instruction as its own separate round object with title set to the instruction text itself (e.g., "Add catnip and stuffing"), rawInstruction set to the original text, summary as a brief description, and targetStitchCount set to null. Place these instruction rounds in their correct sequential position among the stitch rounds.
        - If a required string is unclear, use the closest literal text from the pattern.
        - Do not restate the schema.
        - Do not add any text before or after the JSON object.

        The JSON schema is supplied separately via response_format.
        Return exactly one JSON object and nothing else.
        Never wrap the JSON in markdown.
        Never include commentary, reasoning, apologies, or trailing text.
        Always include every required field.
        Use [] for empty string arrays.
        Use null only where the schema allows null.

        Output example:
        \(outlineExampleJSON)
        """
    }

    static func textOutlinePrompt(extractedText: String, titleHint: String?) -> String {
        """
        Parse the following crochet pattern into the provided outline JSON schema.
        Title hint: \(titleHint ?? "none")

        Pattern text:
        \(extractedText)
        """
    }

    static func roundIRAtomizationSystemPrompt() -> String {
        let supportedTypes = CrochetTermDictionary.supportedStitchTags
            .joined(separator: ", ")

        return """
        You are a crochet master and compiler. Convert each short crochet row or round into canonical Crochet IR, a structured AST that deterministic Swift code will expand into one tap-per-action instructions.

        ## IR overview

        The IR is an AST, not a literal copy of pattern syntax.

        - An `InstructionBlock` owns a `Block` (`body`).
        - A `Block` is an ordered list of `statements`. Sequential execution is the natural meaning of an array — there is no `sequence` statement kind.
        - A `Statement` has one of four kinds: `operation`, `repeat`, `conditional`, `note`.
        - An `Operation` has two fields that separate compiler behavior from UI identity:
          - `semantics` (closed 4-value enum): decides how the compiler expands the operation and counts stitches.
            - `stitchProducing`: produces `count` stitches, each occupying one stitch-slot (sc, hdc, dc, ch, slSt, fpdc, fphdc, fpsc, bpdc, ...).
            - `increase`: produces N stitches into one stitch-slot. `producedStitches` is the output PER SINGLE increase (default 2 — e.g. 2 for sc/hdc/dc inc; set to 3 only for triple-increase). `count` is how many consecutive increases the operation represents; the operation's total output is `count × producedStitches`. Example: 8 consecutive hdc increases producing 16 stitches total → `count = 8, producedStitches = 2` (NEVER `count = 8, producedStitches = 16`).
            - `decrease`: consumes multiple stitch-slots, produces 1 stitch; usually `stitch = dec`.
            - `bookkeeping`: does not produce stitches (turn, skip, joinYarn, fastenOff, changeColor, setWorkingLoop, placeMarker, removeMarker, moveMarker, assembly, custom, ...).
          - `actionTag` (open string): labels the action for the UI. Recommended values:
            - stitchProducing: match the `stitch` value — use the same string (e.g. `actionTag = "sc"` when `stitch = "sc"`, or `actionTag = "cs"` when the pattern uses the custom "cs" abbreviation).
            - increase: `increase` (and put the base stitch in `stitch`, e.g. `stitch = "dc"`)
            - decrease: `decrease`
            - bookkeeping: turn, skip, joinYarn, fastenOff, changeColor, setWorkingLoop, placeMarker, removeMarker, moveMarker, assembly, custom
            - For actions not covered above, invent a camelCase or lowercase tag (letters, digits, underscore, or hyphen) and describe the action in `instruction`. Unknown tags are allowed.

        ## Repeat invariants (IMPORTANT)

        A `repeat` statement represents a HOMOGENEOUS loop. Every iteration of `body` must be identical.

        If a repeated group has any exception on a specific iteration (omission, replacement, addition, "on the last repeat", "on the first repeat", "instead", "except"), DO NOT encode the exception inside the repeat. Normalize it into:

        1. A `repeat` statement with `times` equal to the number of UNCHANGED iterations, whose body is the unchanged sequence.
        2. Flat statements in the enclosing `block.statements` representing the changed iteration(s).
        3. Set `sourceRepeatCount` to the original count declared in the pattern and fill `normalizationNote` with a short human-readable reason.

        Abstract example:
        Input: `[A, B, C] repeat 3 times, omit the final C. Instead, work D.`
        Correct IR (parent.body.statements):
          repeat times=2 body=[A, B, C]
          A
          B
          D
        Incorrect: a `repeat times=3` with some "last iteration transform".

        ## Stitch field — OPEN string with a recommended vocabulary

        The `stitch` field is a free-form string identifying the stitch. Recommended standard values:

        \(supportedTypes)

        However, if the pattern defines a custom stitch abbreviation (via the `abbreviations` list — see below), use the author's abbreviation verbatim as `stitch`. For example, if the pattern defines `cs = cap stitch`, then `stitch = "cs"` (NOT `stitch = "sc"`), `actionTag = "cs"`, and `instruction = "cap stitch (pull up loop, yarn over, pull through first loop only)"` or similar.

        - Never use FLO, BLO, colour text, or placement text as a `stitch` value. Put those in `target` (for location like "top of first ch3", "same stitch", "FLO") or `note` (for free-text commentary).
        - Do not collapse derived post stitches into base stitches. fpdc remains fpdc.
        - Never emit "inc" as a stitch — use `semantics = increase` with the base stitch in `stitch`.

        ## Pattern-level abbreviations

        The request payload may include an `abbreviations` list — pattern-specific author-defined terms. When the raw instruction uses any of these terms:
        1. Use the author's abbreviation as the `stitch` (and `actionTag`) value, NOT a standard stitch.
        2. Put the author's definition (or a short rephrasing of it) into `instruction` so the user sees what the abbreviation actually means.
        3. Never remap a custom abbreviation to a visually similar standard stitch — e.g. `cs` (cap stitch) must stay `cs`, not become `sc` (single crochet).

        ## Rules

        - Return exactly one JSON object and no surrounding text.
        - Preserve source order and the verbatim text of each statement in its `sourceText`.
        - Do not expand repeats yourself. Encode repeats as `repeat` statements (homogeneous after normalization).
        - Use `conditional` for explicit user choices. Preserve all branches even if no choice has been made yet. Multiple conditionals can share the same `choiceID` when the pattern re-refers to the same decision (e.g. "remove the SM if you used one"). When sharing, all sharing conditionals must expose identical `branches.value` sets and the same `defaultBranchValue`.
        - When an instruction names a single supported stitch type (e.g., sc, hdc, dc, fpdc) and applies it across the whole round ("<stitch> around", "<stitch> in each stitch around"), emit exactly one `operation` with `semantics = stitchProducing`, the stitch type, and count equal to `targetStitchCount` if present, otherwise `previousRoundStitchCount`.
        - Non-repeat stitch groups without an explicit repeat count, such as `(hdc, 2 dc, hdc)` applied to a single target, are consecutive operation statements that share the same `target`.
        - Every Statement must include every payload key (operation, repeat, conditional, note). Exactly one payload is non-null for each statement, matching its `kind`.
        - `expectedProducedStitches` equals the explicit target stitch count from the input when present, otherwise null.
        - If the input round contains only a non-stitch instruction, emit a single `operation` with `semantics = bookkeeping` and an appropriate `actionTag`.
        - The body of a `repeat` contains only `operation`, `repeat`, `conditional`, or `note` statements (never nested sequences — block.statements already is the sequence).

        Output example:
        \(irAtomizationExampleJSON)
        """
    }

    static func roundIRAtomizationPrompt(
        projectTitle: String,
        materials: [String],
        rounds: [AtomizationRoundInput]
    ) -> String {
        struct IRRoundInput: Encodable {
            var partName: String
            var title: String
            var rawInstruction: String
            var targetStitchCount: Int?
            var previousRoundStitchCount: Int?
        }

        let irInputs = rounds.map {
            IRRoundInput(
                partName: $0.partName,
                title: $0.title,
                rawInstruction: $0.rawInstruction,
                targetStitchCount: $0.targetStitchCount,
                previousRoundStitchCount: $0.previousRoundStitchCount
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let roundsPayload = (try? encoder.encode(irInputs)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let materialsPayload = materials.isEmpty ? "none" : materials.joined(separator: ", ")

        // Author-defined abbreviations from the outline stage. All rounds share the same
        // pattern-level abbreviation table, so we include it once.
        let abbreviationsPayload: String
        let abbreviations = rounds.first?.abbreviations ?? []
        if abbreviations.isEmpty {
            abbreviationsPayload = "none"
        } else {
            abbreviationsPayload = abbreviations
                .map { "\($0.term) = \($0.definition)" }
                .joined(separator: "\n")
        }

        return """
        Compile these crochet rounds into Crochet IR.

        Project title: \(projectTitle)
        Materials: \(materialsPayload)

        Pattern abbreviations (author-defined; honor these verbatim in `stitch` / `actionTag` / `instruction`):
        \(abbreviationsPayload)

        Input rounds JSON:
        \(roundsPayload)
        """
    }

    static func imageSystemPrompt() -> String {
        """
        You convert crochet pattern images into a single valid JSON object.
        The JSON schema is supplied separately via response_format.
        Return exactly one JSON object and nothing else.
        Never wrap the JSON in markdown.
        Never include commentary, reasoning, apologies, or trailing text.
        Always include every required field.
        Use [] for empty string arrays.
        Use null only where the schema allows null.

        Output example:
        \(imageExampleJSON)
        """
    }

    static func imagePrompt(fileName: String) -> String {
        """
        Read the crochet pattern image and map it into the provided JSON schema.

        Rules:
        - Detect part names, rounds, stitch counts from the image.
        - Extract any author-defined abbreviations (from a "Key"/"Abbreviations"/"Stitches used" section) into the `abbreviations` array. Empty array if none.
        - For each atomicAction, produce: `semantics` ("stitchProducing" / "increase" / "decrease" / "bookkeeping"), `actionTag` (open string, typically same as the stitch abbreviation), `stitchTag` (the stitch abbreviation — use author's term verbatim if defined in abbreviations), `instruction`, `producedStitches`, and optional `note`.
        - Preserve derived stitch abbreviations exactly when they appear. For example, fpdc stays fpdc and must not be reduced to dc.
        - Custom author-defined stitches (e.g. "cs" for "cap stitch") must keep the author's tag — do not remap to standard stitches.
        - Extract only what is visible in the image.
        - Non-stitch instructions between rounds (such as "Add stuffing", "Finish off and sew closed") should be captured as their own round objects with a single atomicAction whose `semantics` is "bookkeeping", `actionTag` is "custom", `stitchTag` is null, `instruction` contains the text, and `producedStitches` is 0.
        - Preserve the original language used in the image when possible.
        - Do not restate the schema.
        - Do not add any text before or after the JSON object.

        File name: \(fileName)
        """
    }

    static func atomizationMatchEvaluationSystemPrompt() -> String {
        """
        You are an independent crochet QA subagent. Compare ONE round's `rawInstruction` with the compiled atomic actions and determine whether the atomization preserved the instruction's meaning.

        Verdicts:
        - `exact_match`: all actionable crochet meaning is preserved with no meaningful omissions or extras.
        - `normalized_match`: semantically faithful, but the atomic actions use acceptable normalization or expansion (for example, "sc around" expanded into repeated single crochet actions).
        - `partial_match`: some important meaning is preserved, but one or more actionable elements are missing, extra, or unclear.
        - `mismatch`: the atomization materially changes the instruction.
        - `not_actionable`: the source is effectively a prose-only note and the atomic result correctly leaves it non-actionable.

        Rules:
        - Judge semantic fidelity, not stylistic wording.
        - `rawInstruction` is the source of truth. Use `irSourceText`, `validationIssues`, `expansionFailure`, `warnings`, and `atomicActions` as evidence.
        - If `validationIssues` contains any error or `expansionFailure` is non-null, you must not return `exact_match` or `normalized_match`.
        - If the verdict is `exact_match` or `normalized_match`, `issueCodes`, `missingElements`, and `extraElements` must all be empty.
        - Do not list acceptable normalization, harmless bookkeeping expansion, or prose-only finishing notes as missing or extra elements.
        - If the verdict is `partial_match` or `mismatch`, you must provide at least one concrete defect through `issueCodes`, `missingElements`, or `extraElements`.
        - Accept harmless normalization such as expanding "sc around" into repeated `sc` actions, or turning "2 hdc in same st" into increase semantics when the meaning is preserved.
        - Treat missing targets, wrong stitch types, wrong counts, omitted bookkeeping steps, extra invented actions, and reordered meaning-changing steps as defects.
        - Use only the schema's `issueCodes`.
        - `missingElements` and `extraElements` should be short concrete phrases, not essays.
        - Keep `rationale` concise and factual.
        - Copy `roundTitle` and `rawInstruction` exactly from the input.
        - Return exactly one JSON object and nothing else.

        Output example:
        \(atomizationMatchEvaluationExampleJSON)
        """
    }

    static func atomizationMatchEvaluationPrompt(input: AtomizationMatchEvaluationInput) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let payload = (try? encoder.encode(input)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

        return """
        Evaluate whether this atomized crochet round faithfully matches the source instruction.

        Round evaluation input JSON:
        \(payload)
        """
    }

    static func atomizationMatchEvaluationRepairSystemPrompt() -> String {
        """
        You repair an atomization match evaluation JSON object so it becomes logically consistent.

        Consistency rules:
        - `exact_match` and `normalized_match` must have empty `issueCodes`, `missingElements`, and `extraElements`.
        - `partial_match` and `mismatch` must include at least one concrete entry in `issueCodes`, `missingElements`, or `extraElements`.
        - If the input reports validation errors or an expansion failure, the verdict must not be `exact_match` or `normalized_match`.
        - `not_actionable` must not include defects.
        - Acceptable normalization or prose-only finishing notes should not be listed as missing or extra elements.
        - Keep `roundTitle` and `rawInstruction` exactly equal to the input.

        The JSON schema is supplied separately via response_format.
        Return exactly one JSON object and nothing else.
        """
    }

    static func atomizationMatchEvaluationRepairPrompt(
        input: AtomizationMatchEvaluationInput,
        invalidEvaluation: AtomizationMatchEvaluation,
        consistencyProblems: [String]
    ) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let inputJSON = (try? encoder.encode(input)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let evaluationJSON = (try? encoder.encode(invalidEvaluation)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let problems = consistencyProblems.map { "- \($0)" }.joined(separator: "\n")

        return """
        Repair the invalid evaluation below so it satisfies the consistency rules.

        Consistency problems:
        \(problems)

        Round evaluation input JSON:
        \(inputJSON)

        Invalid evaluation JSON:
        \(evaluationJSON)
        """
    }

    static func repairSystemPrompt() -> String {
        """
        You repair malformed assistant output into a single valid JSON object.
        The JSON schema is supplied separately via response_format.
        Return exactly one JSON object and nothing else.
        Never wrap the JSON in markdown.
        Never include commentary, reasoning, or trailing text.
        """
    }

    static func repairPrompt(invalidContent: String, originalModelID: String) -> String {
        """
        Fix the malformed assistant output below so it becomes one valid JSON object that matches the provided schema exactly.

        Rules:
        - Preserve the original meaning whenever possible.
        - Do not add fields outside the schema.
        - Ensure every required field is present.
        - Use [] for empty string arrays.
        - Use null only where the schema allows null.
        - If a required string is missing, use the closest safe string value from the malformed content.
        - Output the repaired JSON object only.

        Original model: \(originalModelID)

        Malformed assistant output:
        \(invalidContent)
        """
    }

    static func outlineResponseFormat() -> [String: Any] {
        [
            "type": "json_schema",
            "json_schema": [
                "name": "crochet_pattern_outline_response",
                "strict": true,
                "schema": outlineSchema()
            ]
        ]
    }

    static func irAtomizationResponseFormat() -> [String: Any] {
        [
            "type": "json_schema",
            "json_schema": [
                "name": "crochet_round_ir_atomization_response",
                "strict": true,
                "schema": irAtomizationSchema()
            ]
        ]
    }

    static func imageResponseFormat() -> [String: Any] {
        [
            "type": "json_schema",
            "json_schema": [
                "name": "crochet_pattern_image_response",
                "strict": true,
                "schema": imageSchema()
            ]
        ]
    }

    static func atomizationMatchEvaluationResponseFormat() -> [String: Any] {
        [
            "type": "json_schema",
            "json_schema": [
                "name": "crochet_atomization_match_evaluation",
                "strict": true,
                "schema": atomizationMatchEvaluationSchema()
            ]
        ]
    }

    private static func outlineSchema() -> [String: Any] {
        [
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "projectTitle": ["type": "string"],
                "materials": stringArraySchema(),
                "confidence": ["type": "number"],
                "abbreviations": [
                    "type": "array",
                    "items": abbreviationSchema()
                ],
                "parts": [
                    "type": "array",
                    "items": outlinedPartSchema()
                ]
            ],
            "required": ["projectTitle", "materials", "confidence", "abbreviations", "parts"]
        ]
    }

    private static func abbreviationSchema() -> [String: Any] {
        [
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "term": ["type": "string"],
                "definition": ["type": "string"]
            ],
            "required": ["term", "definition"]
        ]
    }


    private static func irAtomizationSchema() -> [String: Any] {
        [
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "rounds": [
                    "type": "array",
                    "items": irInstructionBlockSchema()
                ]
            ],
            "required": ["rounds"],
            "$defs": [
                "block": irBlockSchema(),
                "statement": irStatementSchema(),
                "operation": irOperationSchema(),
                "repeat": irRepeatBlockSchema(),
                "conditional": irConditionalSchema(),
                "conditionalBranch": irConditionalBranchSchema(),
                "note": irNoteSchema()
            ]
        ]
    }

    private static func irInstructionBlockSchema() -> [String: Any] {
        [
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "title": ["type": "string"],
                "sourceText": ["type": "string"],
                "expectedProducedStitches": nullableIntegerSchema(),
                "body": ["$ref": "#/$defs/block"]
            ],
            "required": ["title", "sourceText", "expectedProducedStitches", "body"]
        ]
    }

    private static func irBlockSchema() -> [String: Any] {
        [
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "statements": [
                    "type": "array",
                    "items": ["$ref": "#/$defs/statement"]
                ],
                "sourceText": nullableStringSchema(),
                "normalizationNote": nullableStringSchema()
            ],
            "required": ["statements", "sourceText", "normalizationNote"]
        ]
    }

    private static func irStatementSchema() -> [String: Any] {
        [
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "kind": [
                    "type": "string",
                    "enum": CrochetIRStatementKindTag.allCases.map(\.rawValue)
                ],
                "sourceText": nullableStringSchema(),
                "operation": nullableObjectSchema(["$ref": "#/$defs/operation"]),
                "repeat": nullableObjectSchema(["$ref": "#/$defs/repeat"]),
                "conditional": nullableObjectSchema(["$ref": "#/$defs/conditional"]),
                "note": nullableObjectSchema(["$ref": "#/$defs/note"])
            ],
            "required": ["kind", "sourceText", "operation", "repeat", "conditional", "note"]
        ]
    }

    private static func irOperationSchema() -> [String: Any] {
        [
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "semantics": [
                    "type": "string",
                    "enum": CrochetIROperationSemantics.allCases.map(\.rawValue)
                ],
                // actionTag is an OPEN string: the prompt recommends common values, but the
                // schema does not constrain it so new actions never require a schema change.
                "actionTag": ["type": "string"],
                // stitch is also OPEN string. Recommended values (standard crochet stitches)
                // are listed in the prompt; for author-defined abbreviations the LLM should
                // use the author's term verbatim (e.g. "cs" for "cap stitch") rather than
                // remapping to a standard stitch. Descriptors like "blo"/"flo" are rejected
                // at validation time because they're not stitch-producing.
                "stitch": nullableStringSchema(),
                "count": ["type": "integer"],
                "instruction": nullableStringSchema(),
                "target": nullableStringSchema(),
                "note": nullableStringSchema(),
                "notePlacement": [
                    "type": "string",
                    "enum": AtomizedNotePlacement.allCases.map(\.rawValue)
                ],
                "producedStitches": nullableIntegerSchema()
            ],
            "required": [
                "semantics",
                "actionTag",
                "stitch",
                "count",
                "instruction",
                "target",
                "note",
                "notePlacement",
                "producedStitches"
            ]
        ]
    }

    private static func irRepeatBlockSchema() -> [String: Any] {
        [
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "times": ["type": "integer"],
                "body": ["$ref": "#/$defs/block"],
                "sourceRepeatCount": nullableIntegerSchema(),
                "normalizationNote": nullableStringSchema()
            ],
            "required": ["times", "body", "sourceRepeatCount", "normalizationNote"]
        ]
    }

    private static func irConditionalSchema() -> [String: Any] {
        [
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "choiceID": ["type": "string"],
                "question": ["type": "string"],
                "branches": [
                    "type": "array",
                    "items": ["$ref": "#/$defs/conditionalBranch"]
                ],
                "defaultBranchValue": nullableStringSchema(),
                "commonBody": nullableObjectSchema(["$ref": "#/$defs/block"])
            ],
            "required": ["choiceID", "question", "branches", "defaultBranchValue", "commonBody"]
        ]
    }

    private static func irConditionalBranchSchema() -> [String: Any] {
        [
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "value": ["type": "string"],
                "label": ["type": "string"],
                "body": ["$ref": "#/$defs/block"]
            ],
            "required": ["value", "label", "body"]
        ]
    }

    private static func irNoteSchema() -> [String: Any] {
        [
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "message": ["type": "string"],
                "sourceText": nullableStringSchema(),
                "emitAsAction": ["type": "boolean"]
            ],
            "required": ["message", "sourceText", "emitAsAction"]
        ]
    }

    private static func imageSchema() -> [String: Any] {
        [
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "projectTitle": ["type": "string"],
                "materials": stringArraySchema(),
                "confidence": ["type": "number"],
                "abbreviations": [
                    "type": "array",
                    "items": abbreviationSchema()
                ],
                "parts": [
                    "type": "array",
                    "items": parsedPartSchema()
                ]
            ],
            "required": ["projectTitle", "materials", "confidence", "abbreviations", "parts"]
        ]
    }

    private static func outlinedPartSchema() -> [String: Any] {
        [
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "name": ["type": "string"],
                "rounds": [
                    "type": "array",
                    "items": outlinedRoundSchema()
                ]
            ],
            "required": ["name", "rounds"]
        ]
    }

    private static func outlinedRoundSchema() -> [String: Any] {
        [
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "title": ["type": "string"],
                "rawInstruction": ["type": "string"],
                "summary": ["type": "string"],
                "targetStitchCount": nullableIntegerSchema(),
                "repeatFromTitle": nullableStringSchema(),
                "repeatToTitle": nullableStringSchema(),
                "repeatUntilCount": nullableIntegerSchema(),
                "repeatAfterRow": nullableIntegerSchema(),
                "rangeStartNumber": nullableIntegerSchema(),
                "rangeEndNumber": nullableIntegerSchema()
            ],
            "required": [
                "title",
                "rawInstruction",
                "summary",
                "targetStitchCount",
                "repeatFromTitle",
                "repeatToTitle",
                "repeatUntilCount",
                "repeatAfterRow",
                "rangeStartNumber",
                "rangeEndNumber"
            ]
        ]
    }

    private static func parsedPartSchema() -> [String: Any] {
        [
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "name": ["type": "string"],
                "rounds": [
                    "type": "array",
                    "items": parsedRoundSchema()
                ]
            ],
            "required": ["name", "rounds"]
        ]
    }

    private static func parsedRoundSchema() -> [String: Any] {
        [
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "title": ["type": "string"],
                "rawInstruction": ["type": "string"],
                "summary": ["type": "string"],
                "targetStitchCount": nullableIntegerSchema(),
                "atomicActions": [
                    "type": "array",
                    "items": parsedAtomicActionSchema()
                ]
            ],
            "required": [
                "title",
                "rawInstruction",
                "summary",
                "targetStitchCount",
                "atomicActions"
            ]
        ]
    }

    private static func parsedAtomicActionSchema() -> [String: Any] {
        [
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "semantics": [
                    "type": "string",
                    "enum": CrochetIROperationSemantics.allCases.map(\.rawValue)
                ],
                "actionTag": ["type": "string"],
                "stitchTag": nullableStringSchema(),
                "instruction": ["type": "string"],
                "producedStitches": nullableIntegerSchema(),
                "note": nullableStringSchema()
            ],
            "required": ["semantics", "actionTag", "stitchTag", "instruction", "producedStitches", "note"]
        ]
    }

    private static func atomizationMatchEvaluationSchema() -> [String: Any] {
        [
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "roundTitle": ["type": "string"],
                "rawInstruction": ["type": "string"],
                "verdict": [
                    "type": "string",
                    "enum": AtomizationMatchVerdict.allCases.map(\.rawValue)
                ],
                "confidence": ["type": "number"],
                "issueCodes": [
                    "type": "array",
                    "items": [
                        "type": "string",
                        "enum": AtomizationMatchIssueCode.allCases.map(\.rawValue)
                    ]
                ],
                "missingElements": stringArraySchema(),
                "extraElements": stringArraySchema(),
                "rationale": ["type": "string"]
            ],
            "required": [
                "roundTitle",
                "rawInstruction",
                "verdict",
                "confidence",
                "issueCodes",
                "missingElements",
                "extraElements",
                "rationale"
            ]
        ]
    }

    private static func stringArraySchema() -> [String: Any] {
        [
            "type": "array",
            "items": ["type": "string"]
        ]
    }

    private static func nullableStringEnumSchema(_ values: [String]) -> [String: Any] {
        [
            "type": ["string", "null"],
            "enum": values + [NSNull()]
        ]
    }

    private static func nullableStringSchema() -> [String: Any] {
        ["type": ["string", "null"]]
    }

    private static func nullableIntegerSchema() -> [String: Any] {
        ["type": ["integer", "null"]]
    }

    private static func nullableArraySchema(items: [String: Any]) -> [String: Any] {
        [
            "type": ["array", "null"],
            "items": items
        ]
    }


    private static func nullableObjectSchema(_ objectSchema: [String: Any]) -> [String: Any] {
        // If the caller passed a {"$ref": "..."} node, `type` is ignored by JSON Schema's
        // $ref semantics (ref replaces sibling properties). Route that case through an
        // explicit anyOf so null is allowed while still resolving the ref.
        if let ref = objectSchema["$ref"] as? String {
            return [
                "anyOf": [
                    ["$ref": ref],
                    ["type": "null"]
                ]
            ]
        }
        var schema = objectSchema
        schema["type"] = ["object", "null"]
        return schema
    }

    private static func nullOnlySchema() -> [String: Any] {
        ["type": "null"]
    }
}

struct FixturePatternParsingClient: PatternLLMParsing {
    private let outlineResponse: PatternOutlineResponse
    private let imageResponse: PatternParseResponse
    private let irRounds: [CrochetIRInstructionBlock]

    init(
        outlineResponse: PatternOutlineResponse,
        imageResponse: PatternParseResponse,
        irResponse: CrochetIRAtomizationResponse
    ) {
        self.outlineResponse = outlineResponse
        self.imageResponse = imageResponse
        self.irRounds = irResponse.rounds
    }

    func parseTextPatternOutline(
        extractedText: String,
        titleHint: String?,
        context: ParseRequestContext
    ) async throws -> PatternOutlineResponse {
        outlineResponse
    }

    func parseTextRoundsToIR(
        projectTitle: String,
        materials: [String],
        rounds: [AtomizationRoundInput],
        context: ParseRequestContext
    ) async throws -> CrochetIRAtomizationResponse {
        CrochetIRAtomizationResponse(rounds: Array(irRounds.prefix(rounds.count)))
    }

    func parseImagePattern(
        imageData: Data,
        mimeType: String,
        fileName: String,
        context: ParseRequestContext
    ) async throws -> PatternParseResponse {
        imageResponse
    }
}
