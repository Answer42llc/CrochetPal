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
            throw PatternImportFailure.fetchFailed(statusCode: httpResponse.statusCode)
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
        guard modelID == "deepseek/deepseek-v3.2" else {
            return nil
        }

        return [
            "require_parameters": true,
            "allow_fallbacks": false,
            "order": ["atlas-cloud/fp8", "siliconflow/fp8"]
        ]
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
          "actionGroups": [
            { "type": "mr", "count": 1, "instruction": null, "producedStitches": null, "note": "With grey yarn." },
            { "type": "ch", "count": 1, "instruction": null, "producedStitches": null, "note": null },
            { "type": "sc", "count": 1, "instruction": null, "producedStitches": null, "note": null },
            { "type": "sc", "count": 1, "instruction": null, "producedStitches": null, "note": null },
            { "type": "sc", "count": 1, "instruction": null, "producedStitches": null, "note": null },
            { "type": "sc", "count": 1, "instruction": null, "producedStitches": null, "note": null },
            { "type": "sc", "count": 1, "instruction": null, "producedStitches": null, "note": null },
            { "type": "sc", "count": 1, "instruction": null, "producedStitches": null, "note": null },
            { "type": "sc", "count": 1, "instruction": null, "producedStitches": null, "note": null },
            { "type": "sl_st", "count": 1, "instruction": null, "producedStitches": null, "note": "Join to the first sc." }
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
        """
        You are a crochet master, I will give you a instruction of a crochet pattern. You will help convert it into compact action groups with follow steps:
            1.Read the instruction carefully,understand what the whole instruction is going to do.
            2.At sometimes, the instrunction might have some little mistake, as typo usually, you could fix it.
            2.Convert actions in the instruction to single crochet action with original order. You should convert it after you understand it, not just divide it simplicity.
            3.Output result as JSON object with the rules below.
        Rules:
        - Return one JSON object only.
        - Preserve the order of the input rounds.
        - rawInstruction is the source of truth. Use partName, title, and targetStitchCount only as supporting context.
        - type must be exactly one enum value from this list: mr, sc, inc, dec, ch, sl_st, blo, flo, fo, hdc, dc, custom.
        - Never output natural-language type names such as "magic loop", "magic ring", "slip stitch", or "fasten off" in the type field.
        - note is optional and should be a short, readable explanation for context such as color changes, placement, special loops, or finishing details.
        - Prefer attaching contextual modifiers to note on the nearest real stitch action instead of emitting a standalone custom action.
        - Use custom only when the step itself is genuinely not one of the known stitch symbols and cannot be attached as a note to a neighboring stitch action.
        - Each actionGroup must represent exactly one base crochet action from the enum.
        - Do not collapse compound shorthand into one action.
        - "sc inc" must become one sc action followed by one inc action.
        - "hdc inc" must become one hdc action followed by one inc action.
        - "1hdc+1sc" must become one hdc action followed by one sc action.
        - "ch1+1sc" must become one ch action followed by one sc action.
        - Expand repeated compound shorthand in order. "(sc inc)x5" must become sc, inc, sc, inc, sc, inc, sc, inc, sc, inc.
        - If an increase or decrease happens in the same stitch as the previous action, put that detail in note on the inc/dec action.
        - count must always be 1. Emit one actionGroup per individual stitch — do not compress consecutive same-type stitches. For example, "7sc" must become seven separate sc actionGroups, each with count 1.
        - Only include instruction when type is custom or the default instruction would be misleading.
        - Only include producedStitches when it differs from the usual default for that symbol.
        - Control actions that do not create stitches, such as color changes, joins, loop placement, skips, and fasten off, should usually become notes rather than standalone actions.
        - If you must use a standalone custom control action, set producedStitches: 0.
        - If some action is going to do in magic ring, you should note it out.
        Golden examples:
        1. Raw instruction: "With grey yarn: Magic loop, ch1, 7sc, slst to the first sc."
           - Correct output groups: mr x1, ch x1, sc x1, sc x1, sc x1, sc x1, sc x1, sc x1, sc x1, sl_st x1
           - Incorrect output groups: custom("magic loop"), custom("slip stitch"), sc x6
           - Incorrect output groups: mr x1, ch x1, sc x7, sl_st x1 (do not compress — each sc must be a separate actionGroup)
        
        Output example:
        \(atomizationExampleJSON)
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
        let materialsText = materials.isEmpty ? "none" : materials.joined(separator: ", ")
        var prompt = """
        Atomize the following crochet rounds into compact action groups.

        Project title: \(projectTitle)
        Materials: \(materialsText)
        Only use each round's rawInstruction as the stitch source of truth.
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
                            "actionGroups": [
                                "type": "array",
                                "items": actionGroupSchema()
                            ]
                        ],
                        "required": ["actionGroups"]
                    ]
                ]
            ],
            "required": ["rounds"]
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
                    "enum": StitchActionType.allCases.map(\.rawValue)
                ],
                "instruction": ["type": "string"],
                "producedStitches": nullableIntegerSchema(),
                "note": nullableStringSchema()
            ],
            "required": ["type", "instruction", "producedStitches", "note"]
        ]
    }

    private static func actionGroupSchema() -> [String: Any] {
        [
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "type": [
                    "type": "string",
                    "enum": StitchActionType.allCases.map(\.rawValue)
                ],
                "count": ["type": "integer"],
                "instruction": nullableStringSchema(),
                "producedStitches": nullableIntegerSchema(),
                "note": nullableStringSchema()
            ],
            "required": ["type", "count", "instruction", "producedStitches", "note"]
        ]
    }

    private static func stringArraySchema() -> [String: Any] {
        [
            "type": "array",
            "items": ["type": "string"]
        ]
    }

    private static func nullableStringSchema() -> [String: Any] {
        ["type": ["string", "null"]]
    }

    private static func nullableIntegerSchema() -> [String: Any] {
        ["type": ["integer", "null"]]
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
