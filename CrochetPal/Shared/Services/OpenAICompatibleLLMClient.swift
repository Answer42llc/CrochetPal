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
              "targetStitchCount": 6,
              "repeatFromTitle": null,
              "repeatToTitle": null,
              "repeatUntilCount": null,
              "repeatAfterRow": null
            },
            {
              "title": "Repeat Rounds 2-5",
              "rawInstruction": "Repeat Rounds 2-5 until you have 20 rounds total.",
              "summary": "Cycle through rounds 2-5 until the body reaches 20 rounds.",
              "targetStitchCount": null,
              "repeatFromTitle": "Round 2",
              "repeatToTitle": "Round 5",
              "repeatUntilCount": 20,
              "repeatAfterRow": 5
            },
            {
              "title": "Add stuffing",
              "rawInstruction": "Add stuffing.",
              "summary": "Add stuffing to the body before closing.",
              "targetStitchCount": null,
              "repeatFromTitle": null,
              "repeatToTitle": null,
              "repeatUntilCount": null,
              "repeatAfterRow": null
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
        - Expand "Rounds N-M" into separate round objects, one per round number. For each expanded round, rewrite rawInstruction to describe only that single round — replace the range prefix (e.g., "Rounds 9-10:") with the individual round prefix (e.g., "Round 9:") so the instruction reads as a standalone single-round instruction. Set repeatFromTitle, repeatToTitle, and repeatUntilCount to null for these expanded rounds.
        - Macro-repeat: When the pattern says to repeat a sequence of previously defined rows/rounds until a total row/round count is reached (e.g., "Repeat Rows 6-13 until you have a total of 118 rows", "Rep rounds 2-5 for a total of 40 rounds"), emit exactly ONE placeholder round object. Set its title to a descriptive label (e.g., "Repeat Rows 6-13"), rawInstruction to the original verbatim text, summary to a brief description, targetStitchCount to null, repeatFromTitle to the title of the first round in the repeating cycle (e.g., "Row 6"), repeatToTitle to the title of the last round in the repeating cycle (e.g., "Row 13"), repeatUntilCount to the total number of rows/rounds the pattern wants (e.g., 118), and repeatAfterRow to the row/round number of the last numbered row that appears before this macro-repeat instruction in the pattern (e.g., if the repeat comes right after Row 13, set to 13; if rows 1-14 exist before the repeat, set to 14; non-stitch instruction rounds like "Foundation Chain" or "Add stuffing" do not count). Do NOT expand the macro-repeat into individual rounds yourself — the app will handle the expansion. This is different from "Rounds N-M" range expansion: range expansion is for one instruction covering multiple consecutive rounds with the same work; macro-repeat is for re-cycling through a previously defined sequence of rounds to reach a total count.
        - If additional instructions follow the macro-repeat in the same sentence or paragraph (such as "Then do one more row of sc" or "Weave in ends"), capture each such instruction as its own separate round object placed after the macro-repeat placeholder, following the existing rule for non-stitch instructions.
        - For all normal rounds and non-stitch instruction rounds, set repeatFromTitle, repeatToTitle, repeatUntilCount, and repeatAfterRow to null.
        - Do not generate atomicActions in this stage.
        - targetStitchCount must only be set when the pattern text explicitly states a stitch count for that round (e.g., a number in parentheses such as "(18)" or "(6 sts)" at the end of the instruction). Do NOT calculate or infer targetStitchCount from the stitch operations — even if you can derive it mathematically. If no explicit stitch count appears in the pattern text for that round, set targetStitchCount to null.
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
        - Each input round represents exactly one round of work. The title field identifies which single round it is. If rawInstruction still contains a multi-round range prefix like "Rounds 9-10", treat the instruction body as applying to just this single round — do not wrap it in a repeat segment for the number of rounds in the range. The range notation means the same instruction was used for multiple consecutive rounds, each sent to you independently.
        - stitchRun.type must be exactly one enum value from this list: \(supportedTypes).
        - control.kind must be exactly one enum value from this list: \(controlKinds).
        - Never use custom or control as an escape hatch for stitch-like content.
        - Never output descriptive terms such as blo, flo, front loop only, back loop only, or color-change text as stitchRun.type.
        - Never output natural-language stitch names such as "magic loop", "magic ring", "slip stitch", or "fasten off" as stitchRun.type.
        - Do not collapse derived stitch abbreviations into their base stitch. For example, fpdc must stay fpdc, not dc with a "front post" note.
        - Compress consecutive identical stitches into one stitchRun. "7sc" must become one stitchRun with type sc and count 7.
        - Use repeat when the source expresses repeated structure. "(sc 2, inc) x 3" should become one repeat segment whose sequence is [sc x2, inc x1] and whose times is 3.
        - Only use repeat kind when the source contains an explicit repetition count (×3, x3, "3 times", "4x", etc.). A parenthesized or bracketed stitch group WITHOUT a ×N suffix is NOT a repeat — it means multiple stitches worked into the same stitch or stitch space. Common non-repeat groups: "(hdc, 2 dc, hdc)" (ear/peak into one st), "(3 dc in same st)" (shell/fan), "[dc, ch 1, dc] in corner" (V-stitch), "(yo, insert, pull up loop)" technique descriptions. Expand these as consecutive stitchRun segments with notes indicating they share the same stitch.
        - times must always be a concrete positive integer when kind=repeat. Never output kind=repeat with times=null. If you cannot determine a concrete integer for times, do not use kind=repeat — flatten the contents as individual stitchRun segments instead.
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
        - Instruction-only rounds (rounds with no stitch content, such as "Add stuffing" or "Finish off and sew closed") must produce exactly one control segment with kind=custom. The instruction field must contain the full instruction text.
        - Only include instruction when the default instruction would be misleading.
        - Every segment must include verbatim with the exact source snippet that the segment came from.
        - previousRoundStitchCount tells you how many stitches are available to work into from the previous round. It is a hard physical constraint — you cannot work into stitches that do not exist.
        - ALWAYS use previousRoundStitchCount (when provided) to verify and correct explicit repeat counts. This applies regardless of whether targetStitchCount is null or not. When targetStitchCount is null, previousRoundStitchCount is the ONLY available constraint and becomes even more critical.
        - Conflict resolution: calculate consumedPerRepeat (sum of stitches each action consumes). If previousRoundStitchCount / consumedPerRepeat gives an integer that differs from the explicit repeat count, use previousRoundStitchCount / consumedPerRepeat. This rule applies whether targetStitchCount is present or null.
        - For "around" instructions (e.g., "sc around", "dc around") with no explicit count: when previousRoundStitchCount is provided, the count equals previousRoundStitchCount (one stitch per available stitch from the previous round).
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
        8. Raw instruction: "(sc 6, inc) ×4. (24)" with targetStitchCount=24, previousRoundStitchCount=21
           - Each repeat: sc 6 + inc 1 = consumes 7 stitches, produces 8 stitches
           - Available stitches: 21 / 7 = 3 repeats (not 4 as written)
           - Verification: 3 × 8 = 24 = targetStitchCount ✓
           - Correct output: repeat(sequence=[stitchRun(sc x6), stitchRun(inc x1)], times=3)
           - Incorrect output: times=4 — the raw instruction has a typo; previousRoundStitchCount proves only 3 repeats fit.
        9. Raw instruction: "(sc 6, inc) ×3. (32)" with targetStitchCount=32, previousRoundStitchCount=21
           - Each repeat: consumes 7, produces 8
           - Available stitches: 21 / 7 = 3 repeats (matches ×3)
           - Produced: 3 × 8 = 24 ≠ targetStitchCount (32), but previousRoundStitchCount confirms ×3
           - Correct output: repeat(times=3) — trust previousRoundStitchCount over targetStitchCount.
           - Incorrect output: times=4 — would require 28 stitches but only 21 are available.
        10. Raw instruction: "Add catnip and stuffing."
           - This is an instruction-only round with no stitches.
           - Correct output: one control(kind=custom, instruction="Add catnip and stuffing")
           - Incorrect output: any stitchRun segment — this round has no stitch content.
        11. title: "Round 9", rawInstruction: "Rounds 9-10: sc around. (18)" with targetStitchCount=18, previousRoundStitchCount=18
           - "Rounds 9-10" means this same instruction applies to Round 9 and Round 10, each sent independently.
           - This input is for Round 9 alone: 18 sc stitches.
           - Correct output: stitchRun(sc x18, note="around", notePlacement=all)
           - Incorrect output: repeat(times=2, sequence=[stitchRun(sc x18)]) — "Rounds 9-10" is NOT a repeat instruction; each round is sent as a separate input.
        12. Raw instruction: "(sc 6, inc) ×4" with targetStitchCount=null, previousRoundStitchCount=21
           - targetStitchCount is null (pattern did not provide a stitch count)
           - Each repeat: sc 6 + inc 1 = consumes 7 stitches, produces 8 stitches
           - Available stitches from previous round: 21 / 7 = 3 repeats (not 4 as written)
           - previousRoundStitchCount is the ONLY constraint; it proves only 3 repeats fit
           - Correct output: repeat(sequence=[stitchRun(sc x6), stitchRun(inc x1)], times=3)
           - Incorrect output: times=4 — would require 28 stitches but only 21 are available.
        13. Raw instruction: "sc around" with targetStitchCount=null, previousRoundStitchCount=21
           - targetStitchCount is null, but previousRoundStitchCount=21 tells us there are 21 stitches to work into
           - "sc around" means one sc in each available stitch
           - Correct output: stitchRun(sc x21, note="around", notePlacement=all)
           - Incorrect output: any count other than 21 — "around" means working into every available stitch from the previous round.
        14. Raw instruction: "in flo of next st (hdc, 2 dc, hdc) to form first ear"
           - (hdc, 2 dc, hdc) has no ×N suffix — these are stitches worked into ONE stitch (ear/peak formation), not a repeat
           - Correct output: stitchRun(hdc x1, note="in FLO of next stitch", notePlacement=first), stitchRun(dc x2, note="in same FLO stitch"), stitchRun(hdc x1, note="ear formed, in same FLO stitch", notePlacement=last)
           - Incorrect output: repeat(times=null, ...) — times must never be null; a (stitch group) without ×N is not a repeat.
           - Contrast: "(hdc, 2 dc, hdc) ×3" WOULD be repeat(times=3) because ×3 is explicit.
        15. Raw instruction: "(3 dc in same st)"
           - No ×N repeat count — this is a shell/fan stitch: 3 dc all worked into the same stitch
           - Correct output: stitchRun(dc x3, note="in same stitch", notePlacement=all)
           - Incorrect output: repeat(times=null, sequence=[stitchRun(dc x1)]) — "3 dc" is the stitch count, not a repeat multiplier for the group.

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
        - Non-stitch instructions between rounds (such as "Add stuffing", "Finish off and sew closed") should be captured as their own round objects with a single atomicAction of type "custom", instruction containing the text, and producedStitches 0.
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
                "targetStitchCount": nullableIntegerSchema(),
                "repeatFromTitle": nullableStringSchema(),
                "repeatToTitle": nullableStringSchema(),
                "repeatUntilCount": nullableIntegerSchema(),
                "repeatAfterRow": nullableIntegerSchema()
            ],
            "required": [
                "title",
                "rawInstruction",
                "summary",
                "targetStitchCount",
                "repeatFromTitle",
                "repeatToTitle",
                "repeatUntilCount",
                "repeatAfterRow"
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
