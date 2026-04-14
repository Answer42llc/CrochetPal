import Foundation

protocol PatternLLMParsing {
    func parseTextPatternOutline(
        extractedText: String,
        titleHint: String?,
        context: ParseRequestContext
    ) async throws -> PatternOutlineResponse

    func atomizeTextRounds(
        projectTitle: String,
        materials: [String],
        rounds: [AtomizationRoundInput],
        context: ParseRequestContext
    ) async throws -> RoundAtomizationResponse

    func parseImagePattern(
        imageData: Data,
        mimeType: String,
        fileName: String,
        context: ParseRequestContext
    ) async throws -> PatternParseResponse
}

final class OpenAICompatibleLLMClient: PatternLLMParsing {
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

    func atomizeTextRounds(
        projectTitle: String,
        materials: [String],
        rounds: [AtomizationRoundInput],
        context: ParseRequestContext
    ) async throws -> RoundAtomizationResponse {
        let prompt = PromptFactory.roundAtomizationPrompt(
            projectTitle: projectTitle,
            materials: materials,
            rounds: rounds
        )
        let messages: [[String: Any]] = [
            ["role": "system", "content": PromptFactory.roundAtomizationSystemPrompt()],
            ["role": "user", "content": prompt]
        ]
        return try await sendChatCompletion(
            modelID: configuration.atomizationModelID,
            messagePayload: messages,
            context: context,
            modelKind: "round_atomizer",
            responseFormat: PromptFactory.atomizationResponseFormat(),
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
      "parts": [
        {
          "name": "Body",
          "rounds": [
            {
              "title": "Round 1",
              "rawInstruction": "In a MR, sc 6. (6)",
              "summary": "Create a magic ring and work six single crochets into it.",
              "targetStitchCount": 6
            }
          ]
        }
      ]
    }
    """

    private static let atomizationExampleJSON = """
    {
      "rounds": [
        {
          "segments": [
            {
              "kind": "stitchRun",
              "type": "ch",
              "count": 114,
              "instruction": null,
              "producedStitches": null,
              "note": "With off white yarn.",
              "notePlacement": "all",
              "times": null,
              "sequence": null,
              "controlKind": null,
              "verbatim": "With off white, ch 114"
            }
          ]
        }
      ]
    }
    """

    private static let imageExampleJSON = """
    {
      "projectTitle": "Mouse Cat Toy",
      "materials": ["3.75 mm crochet hook"],
      "confidence": 0.91,
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
                { "type": "mr", "instruction": "mr", "producedStitches": 0, "note": null },
                { "type": "sc", "instruction": "sc", "producedStitches": 1, "note": null }
              ]
            }
          ]
        }
      ]
    }
    """

    static func textOutlineSystemPrompt() -> String {
        """
        You are a crochet master. Convert the provided crochet pattern text into one valid JSON object.
        Extract:
        - projectTitle: the thing the pattern makes, not the blog post title
        - materials
        - confidence
        - parts and rounds

        Rules:
        - Keep only actionable crochet content.
        - Preserve part and round order from the source.
        - Preserve part names such as Body, Head, Eyes, Ears when present.
        - Expand "Rounds N-M" into separate round objects, one per round number.
        - Do not generate atomicActions in this stage.
        - If target stitch count is missing, use null.
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

    static func roundAtomizationSystemPrompt() -> String {
        let supportedTypes = CrochetTermDictionary.supportedAtomicActionTypes
            .map(\.rawValue)
            .joined(separator: ", ")
        let controlKinds = ControlSegmentKind.allCases.map(\.rawValue).joined(separator: ", ")

        return """
        You are a crochet master. Convert each crochet round into structured summary segments that a deterministic program can expand into final atomic actions.

        Segment kinds:
        - stitchRun: one stitch type repeated count times
        - repeat: a repeated sequence of segments
        - control: a non-stitch control action such as turning the work

        Rules:
        - Return one JSON object only.
        - Preserve the order of the input rounds.
        - rawInstruction is the source of truth. Use summary only to improve note clarity.
        - stitchRun.type must be exactly one enum value from this list: \(supportedTypes).
        - control.kind must be exactly one enum value from this list: \(controlKinds).
        - Never use custom or control as an escape hatch for stitch-like content.
        - Never output descriptive terms such as blo, flo, front loop only, back loop only, or color-change text as stitchRun.type.
        - Never output natural-language stitch names such as "magic loop", "magic ring", "slip stitch", or "fasten off" as stitchRun.type.
        - Do not collapse derived stitch abbreviations into their base stitch. For example, fpdc must stay fpdc, not dc with a "front post" note.
        - Compress consecutive identical stitches into one stitchRun. "7sc" must become one stitchRun with type sc and count 7.
        - Use repeat when the source expresses repeated structure. "(sc 2, inc) x 3" should become one repeat segment whose sequence is [sc x2, inc x1] and whose times is 3.
        - Preserve the original stitch order after expansion.
        - stitchRun.note must be short, readable context. Use notePlacement to say whether the note applies to the first stitch, last stitch, or every stitch in that run.
        - For stitchRun, notePlacement must never be null. If stitchRun.note is null, use notePlacement=first as the default placeholder.
        - Use notePlacement=first for leading placement guidance such as "in the 2nd ch from the hook".
        - Use notePlacement=last for trailing follow-up guidance such as "change color".
        - Use notePlacement=all for context that applies to the whole run such as yarn color or FLO/BLO placement.
        - For stitchRun, producedStitches must be null. The app already calculates stitch contribution from stitchRun.type.
        - Every segment object must include every schema key. When a field does not apply to that segment kind, set it to null instead of omitting it.
        - Contextual modifiers such as color, loop placement, round references, and placement guidance should stay in note, not control.
        - control is only for standalone control steps that should remain separate after expansion, such as turn or skip (skipping one or more stitches).
        - If control.kind is custom, instruction must contain the exact control wording to preserve.
        - Only include instruction when the default instruction would be misleading.
        - Every segment must include verbatim with the exact source snippet that the segment came from.
        Golden examples:
        1. Raw instruction: "With off white, ch 114"
           - Correct output: one stitchRun(type=ch, count=114, note="with off white yarn", notePlacement=all)
           - Incorrect output: 114 separate stitchRun segments
        2. Raw instruction: "Row 1: 1 sc in the 2nd ch from the hook and in each ch across. (113 sc) Ch 1, turn."
           - Correct output: stitchRun(sc x113, notePlacement=first), stitchRun(ch x1), control(turn)
        3. Raw instruction: "R3: sc around (12), change color"
           - Correct output: stitchRun(sc x12, note="change color", notePlacement=last)
        4. Raw instruction: "R8: work in FLO of R5: sc 12"
           - Correct output: stitchRun(sc x12, note="work in FLO of Round 5", notePlacement=all)
        5. Raw instruction: "fpdc around next st"
           - Correct output: stitchRun(type=fpdc, count=1)
           - Incorrect output: stitchRun(type=dc, note="front post")
        6. Raw instruction: "1 sc in the first 2 sc, *fpdc around next st from 3 rows below, sk the sc behind the fpdc, 1 sc in each of the next 2 sc* repeat across. (113 stitches)" with targetStitchCount=113
           - Correct output: stitchRun(sc x2), repeat(sequence=[stitchRun(fpdc x1), control(kind=skip, instruction="skip the sc behind the post stitch"), stitchRun(sc x2)], times=37) — times = (113 - 2) / 3 = 37
           - Incorrect output: stitchRun(type=sc, instruction="skip") — skip is not a stitch, it is a control step. Also incorrect: times=null — always calculate a concrete integer for times from targetStitchCount.
        7. Raw instruction: "skip next 2 sts, 3dc in next st"
           - Correct output: control(kind=skip, instruction="skip next 2 sts"), stitchRun(dc x3)
           - Incorrect output: stitchRun with instruction="skip"

        """
    }

    static func roundAtomizationPrompt(
        projectTitle: String,
        materials: [String],
        rounds: [AtomizationRoundInput]
    ) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let roundsPayload = (try? encoder.encode(rounds)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        var prompt = """
        Atomize the following crochet rounds into structured summary segments.

        Project title: \(projectTitle)
        """

        prompt += """

        Input rounds JSON:
        \(roundsPayload)
        """
        return prompt
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
        - Detect part names, rounds, stitch counts, and abbreviations from the image.
        - sequence details are not needed; only return atomicActions with type, instruction, producedStitches, and optional note.
        - Preserve derived stitch abbreviations exactly when they appear. For example, fpdc stays fpdc and must not be reduced to dc.
        - Extract only what is visible in the image.
        - Preserve the original language used in the image when possible.
        - Do not restate the schema.
        - Do not add any text before or after the JSON object.

        File name: \(fileName)
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

    static func atomizationResponseFormat() -> [String: Any] {
        [
            "type": "json_schema",
            "json_schema": [
                "name": "crochet_round_atomization_response",
                "strict": true,
                "schema": atomizationSchema()
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

    private static func outlineSchema() -> [String: Any] {
        [
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "projectTitle": ["type": "string"],
                "materials": stringArraySchema(),
                "confidence": ["type": "number"],
                "parts": [
                    "type": "array",
                    "items": outlinedPartSchema()
                ]
            ],
            "required": ["projectTitle", "materials", "confidence", "parts"]
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
                "parts": [
                    "type": "array",
                    "items": parsedPartSchema()
                ]
            ],
            "required": ["projectTitle", "materials", "confidence", "parts"]
        ]
    }

    private static func atomizationSchema() -> [String: Any] {
        [
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "rounds": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "additionalProperties": false,
                        "properties": [
                            "segments": [
                                "type": "array",
                                "items": [
                                    "$ref": "#/$defs/segment"
                                ]
                            ]
                        ],
                        "required": ["segments"]
                    ]
                ]
            ],
            "required": ["rounds"],
            "$defs": [
                "segment": atomizationSegmentSchema(
                    allowedKinds: AtomizedSegmentKind.allCases,
                    timesSchema: nullableIntegerSchema(),
                    sequenceSchema: nullableArraySchema(items: ["$ref": "#/$defs/repeatSequenceSegment"])
                ),
                "repeatSequenceSegment": atomizationSegmentSchema(
                    allowedKinds: [.stitchRun, .control],
                    timesSchema: nullOnlySchema(),
                    sequenceSchema: nullOnlySchema()
                )
            ]
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
                "targetStitchCount": nullableIntegerSchema()
            ],
            "required": [
                "title",
                "rawInstruction",
                "summary",
                "targetStitchCount"
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
                "type": [
                    "type": "string",
                    "enum": CrochetTermDictionary.supportedAtomicActionTypes.map(\.rawValue)
                ],
                "instruction": ["type": "string"],
                "producedStitches": nullableIntegerSchema(),
                "note": nullableStringSchema()
            ],
            "required": ["type", "instruction", "producedStitches", "note"]
        ]
    }

    private static func atomizationSegmentSchema(
        allowedKinds: [AtomizedSegmentKind],
        timesSchema: [String: Any],
        sequenceSchema: [String: Any]
    ) -> [String: Any] {
        [
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "kind": [
                    "type": "string",
                    "enum": allowedKinds.map(\.rawValue)
                ],
                "type": nullableStringEnumSchema(CrochetTermDictionary.supportedAtomicActionTypes.map(\.rawValue)),
                "count": nullableIntegerSchema(),
                "instruction": nullableStringSchema(),
                "producedStitches": nullOnlySchema(),
                "note": nullableStringSchema(),
                "notePlacement": nullableStringEnumSchema(AtomizedNotePlacement.allCases.map(\.rawValue)),
                "times": timesSchema,
                "sequence": sequenceSchema,
                "controlKind": nullableStringEnumSchema(ControlSegmentKind.allCases.map(\.rawValue)),
                "verbatim": ["type": "string"]
            ],
            "required": atomizationSegmentRequiredKeys()
        ]
    }

    private static func atomizationSegmentRequiredKeys() -> [String] {
        [
            "kind",
            "type",
            "count",
            "instruction",
            "producedStitches",
            "note",
            "notePlacement",
            "times",
            "sequence",
            "controlKind",
            "verbatim"
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

    private static func nullOnlySchema() -> [String: Any] {
        ["type": "null"]
    }
}

struct FixturePatternParsingClient: PatternLLMParsing {
    private let outlineResponse: PatternOutlineResponse
    private let imageResponse: PatternParseResponse
    private let atomizationRounds: [AtomizedPatternRound]

    init(
        outlineResponse: PatternOutlineResponse,
        imageResponse: PatternParseResponse,
        atomizationResponse: RoundAtomizationResponse
    ) {
        self.outlineResponse = outlineResponse
        self.imageResponse = imageResponse
        self.atomizationRounds = atomizationResponse.rounds
    }

    func parseTextPatternOutline(
        extractedText: String,
        titleHint: String?,
        context: ParseRequestContext
    ) async throws -> PatternOutlineResponse {
        outlineResponse
    }

    func atomizeTextRounds(
        projectTitle: String,
        materials: [String],
        rounds: [AtomizationRoundInput],
        context: ParseRequestContext
    ) async throws -> RoundAtomizationResponse {
        RoundAtomizationResponse(rounds: Array(atomizationRounds.prefix(rounds.count)))
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
