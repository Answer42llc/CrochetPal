import XCTest
@testable import CrochetPal

final class PatternImportServiceTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        URLProtocol.registerClass(MockURLProtocol.self)
    }

    override class func tearDown() {
        URLProtocol.unregisterClass(MockURLProtocol.self)
        super.tearDown()
    }

    /// nullableStringEnumSchema 的结构是 `{ "anyOf": [ {"type":"string","enum":[...]}, {"type":"null"} ] }`。
    /// 这里抽出 enum 里的字符串值，便于断言。
    private func extractNullableEnumStrings(from schema: [String: Any]) throws -> [String] {
        let anyOf = try XCTUnwrap(schema["anyOf"] as? [[String: Any]])
        let stringBranch = try XCTUnwrap(anyOf.first(where: { $0["type"] as? String == "string" }))
        return try XCTUnwrap(stringBranch["enum"] as? [String])
    }

    private func nullableEnumAllowsNull(from schema: [String: Any]) throws -> Bool {
        let anyOf = try XCTUnwrap(schema["anyOf"] as? [[String: Any]])
        return anyOf.contains(where: { $0["type"] as? String == "null" })
    }

    func testImportWebPatternBuildsOutlineRecordWithPendingRounds() async throws {
        let html = try fixture(named: "mouse-pattern", extension: "html")
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://example.com/pattern")
            let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(html.utf8))
        }

        let session = URLSession(configuration: configuration())
        let importer = PatternImportService(
            parserClient: FixturePatternParsingClient(
                outlineResponse: SampleDataFactory.demoOutlineResponse,
                imageResponse: SampleDataFactory.demoImageParseResponse,
                atomizationResponse: SampleDataFactory.demoAtomizationResponse
            ),
            extractor: HTMLExtractionService(),
            session: session,
            logger: ConsoleTraceLogger()
        )

        let record = try await importer.importWebPattern(from: "https://example.com/pattern")

        XCTAssertEqual(record.project.title, "Mouse Cat Toy")
        XCTAssertEqual(record.project.parts.count, 2)
        XCTAssertEqual(record.project.parts.first?.rounds.count, 2)
        XCTAssertTrue(record.project.parts.flatMap(\.rounds).allSatisfy { $0.atomizationStatus == .pending })
        XCTAssertTrue(record.project.parts.flatMap(\.rounds).allSatisfy(\.atomicActions.isEmpty))
    }

    func testImportTextPatternBuildsOutlineRecordWithPendingRounds() async throws {
        let parserClient = OutlineTextCaptureClient(response: SampleDataFactory.demoOutlineResponse)
        let importer = PatternImportService(
            parserClient: parserClient,
            extractor: HTMLExtractionService(),
            logger: ConsoleTraceLogger()
        )

        let record = try await importer.importTextPattern(from: "\n  Mouse Cat Toy\nRound 1: In a MR, sc 6. (6)\n")

        XCTAssertEqual(record.project.source.type, PatternSourceType.text)
        XCTAssertEqual(record.project.source.displayName, "Pasted Pattern")
        XCTAssertNil(record.project.source.sourceURL)
        XCTAssertNil(record.project.source.fileName)
        XCTAssertTrue(record.project.parts.flatMap(\.rounds).allSatisfy { $0.atomizationStatus == .pending })
        XCTAssertTrue(record.project.parts.flatMap(\.rounds).allSatisfy(\.atomicActions.isEmpty))

        let request = await parserClient.capturedTextRequest()
        XCTAssertEqual(request.extractedText, "Mouse Cat Toy\nRound 1: In a MR, sc 6. (6)")
        XCTAssertNil(request.titleHint)
        XCTAssertEqual(request.context?.sourceType, .text)
    }

    func testImportWebPatternSendsAllRemainingTextNodesToOutlineLLM() async throws {
        let html = """
        <html>
          <head>
            <title>Pattern Title</title>
            <style>body { color: red; }</style>
          </head>
          <body>
            <nav>Home</nav>
            <article>
              <h1>Pattern Title</h1>
              <p>Intro paragraph.</p>
              <p>Round <strong>1</strong>: sc 6. (6)</p>
            </article>
            <aside>Related posts</aside>
            <section>
              <p>Comments</p>
            </section>
          </body>
        </html>
        """

        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://example.com/pattern")
            let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(html.utf8))
        }

        let parserClient = OutlineTextCaptureClient(response: SampleDataFactory.demoOutlineResponse)
        let session = URLSession(configuration: configuration())
        let importer = PatternImportService(
            parserClient: parserClient,
            extractor: HTMLExtractionService(),
            session: session,
            logger: ConsoleTraceLogger()
        )

        _ = try await importer.importWebPattern(from: "https://example.com/pattern")

        let request = await parserClient.capturedTextRequest()
        XCTAssertEqual(request.titleHint, "Pattern Title")
        XCTAssertEqual(
            request.extractedText,
            [
                "Pattern Title",
                "Intro paragraph.",
                "Round 1: sc 6. (6)",
                "Comments"
            ].joined(separator: "\n")
        )
    }

    func testImportWebPatternLogsOutlinePayloadBeforeSendingToLLM() async throws {
        let html = """
        <html>
          <head>
            <title>Pattern Title</title>
          </head>
          <body>
            <article>
              <h1>Pattern Title</h1>
              <p>Intro paragraph.</p>
              <p>Round <strong>1</strong>: sc 6. (6)</p>
            </article>
          </body>
        </html>
        """

        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://example.com/pattern")
            let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(html.utf8))
        }

        let eventCapture = EventCapture()
        let session = URLSession(configuration: configuration())
        let importer = PatternImportService(
            parserClient: FixturePatternParsingClient(
                outlineResponse: SampleDataFactory.demoOutlineResponse,
                imageResponse: SampleDataFactory.demoImageParseResponse,
                atomizationResponse: SampleDataFactory.demoAtomizationResponse
            ),
            extractor: HTMLExtractionService(),
            session: session,
            logger: ConsoleTraceLogger { eventCapture.events.append($0) }
        )

        _ = try await importer.importWebPattern(from: "https://example.com/pattern")

        let event = try XCTUnwrap(eventCapture.events.first(where: { $0.stage == "web_outline_payload" }))
        XCTAssertEqual(event.reason, "sending_outline_text_to_llm")
        XCTAssertEqual(event.metadata["titleHint"], "Pattern Title")
    }

    func testAtomizeRoundsBuildsAtomicActionsLocally() async throws {
        let html = try fixture(named: "mouse-pattern", extension: "html")
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(html.utf8))
        }

        let session = URLSession(configuration: configuration())
        let importer = PatternImportService(
            parserClient: FixturePatternParsingClient(
                outlineResponse: SampleDataFactory.demoOutlineResponse,
                imageResponse: SampleDataFactory.demoImageParseResponse,
                atomizationResponse: SampleDataFactory.demoAtomizationResponse
            ),
            extractor: HTMLExtractionService(),
            session: session,
            logger: ConsoleTraceLogger()
        )

        let record = try await importer.importWebPattern(from: "https://example.com/pattern")
        let targets = try firstRoundReferences(in: record.project, count: 2)
        let updates = try await importer.atomizeRounds(in: record.project, targets: targets)

        XCTAssertEqual(updates.count, 2)
        XCTAssertEqual(updates[0].atomicActions.count, 7)
        XCTAssertNil(updates[0].atomicActions.first?.instruction)
        XCTAssertEqual(updates[0].atomicActions.last?.sequenceIndex, 6)
        XCTAssertEqual(updates[1].atomicActions.count, 9)
        XCTAssertEqual(updates[1].atomicActions[2].type, .inc)
        XCTAssertEqual(updates[1].atomicActions[2].producedStitches, 2)
    }

    func testAtomizeRoundsBuildsAtomicActionsForTextProject() async throws {
        let importer = PatternImportService(
            parserClient: FixturePatternParsingClient(
                outlineResponse: SampleDataFactory.demoOutlineResponse,
                imageResponse: SampleDataFactory.demoImageParseResponse,
                atomizationResponse: SampleDataFactory.demoAtomizationResponse
            ),
            extractor: HTMLExtractionService(),
            logger: ConsoleTraceLogger()
        )

        let record = try await importer.importTextPattern(from: "Mouse Cat Toy\nRound 1: In a MR, sc 6. (6)")
        let targets = try firstRoundReferences(in: record.project, count: 2)
        let updates = try await importer.atomizeRounds(in: record.project, targets: targets)

        XCTAssertEqual(record.project.source.type, .text)
        XCTAssertEqual(updates.count, 2)
        XCTAssertEqual(updates[0].atomicActions.count, 7)
        XCTAssertEqual(updates[1].atomicActions[2].type, .inc)
    }

    func testAtomizeRoundsIncludesRoundSummaryInAtomizationInput() async throws {
        let parserClient = AtomizationInputCaptureClient(
            outlineResponse: SampleDataFactory.demoOutlineResponse,
            atomizationResponse: SampleDataFactory.demoAtomizationResponse
        )
        let importer = PatternImportService(
            parserClient: parserClient,
            extractor: HTMLExtractionService(),
            logger: ConsoleTraceLogger()
        )

        let record = try await importer.importTextPattern(from: "Mouse Cat Toy\nRound 1: In a MR, sc 6. (6)")
        let targets = try firstRoundReferences(in: record.project, count: 1)

        _ = try await importer.atomizeRounds(in: record.project, targets: targets)

        let capturedRounds = await parserClient.capturedRounds()
        XCTAssertEqual(capturedRounds.count, 1)
        XCTAssertEqual(capturedRounds.first?.partName, "Body")
        XCTAssertEqual(capturedRounds.first?.title, "Round 1")
        XCTAssertEqual(capturedRounds.first?.rawInstruction, "In a MR, sc 6. (6)")
        XCTAssertEqual(capturedRounds.first?.summary, "Create a magic ring and crochet six single crochets into it.")
        XCTAssertEqual(capturedRounds.first?.targetStitchCount, 6)
    }

    func testImportImagePatternUsesFixtureClient() async throws {
        let importer = PatternImportService(
            parserClient: FixturePatternParsingClient(
                outlineResponse: SampleDataFactory.demoOutlineResponse,
                imageResponse: SampleDataFactory.demoImageParseResponse,
                atomizationResponse: SampleDataFactory.demoAtomizationResponse
            ),
            extractor: HTMLExtractionService(),
            logger: ConsoleTraceLogger()
        )

        let record = try await importer.importImagePattern(data: SampleDataFactory.sampleImageData, fileName: "sample.png")

        XCTAssertEqual(record.project.source.type, PatternSourceType.image)
        XCTAssertEqual(record.project.totalAtomicActionCount, 23)
        XCTAssertTrue(record.project.parts.flatMap(\.rounds).allSatisfy { $0.atomizationStatus == .ready })
    }

    func testImportImagePatternPreservesRawModelNote() async throws {
        var imageResponse = SampleDataFactory.demoImageParseResponse
        imageResponse.parts[0].rounds[0].atomicActions[0].note = "in a MR"

        let importer = PatternImportService(
            parserClient: FixturePatternParsingClient(
                outlineResponse: SampleDataFactory.demoOutlineResponse,
                imageResponse: imageResponse,
                atomizationResponse: SampleDataFactory.demoAtomizationResponse
            ),
            extractor: HTMLExtractionService(),
            logger: ConsoleTraceLogger()
        )

        let record = try await importer.importImagePattern(data: SampleDataFactory.sampleImageData, fileName: "sample.png")

        XCTAssertEqual(record.project.parts[0].rounds[0].atomicActions[0].note, "in a MR")
    }

    func testImportImagePatternNormalizesBlankInstructionToNil() async throws {
        var imageResponse = SampleDataFactory.demoImageParseResponse
        imageResponse.parts[0].rounds[0].atomicActions[0].instruction = "   "

        let importer = PatternImportService(
            parserClient: FixturePatternParsingClient(
                outlineResponse: SampleDataFactory.demoOutlineResponse,
                imageResponse: imageResponse,
                atomizationResponse: SampleDataFactory.demoAtomizationResponse
            ),
            extractor: HTMLExtractionService(),
            logger: ConsoleTraceLogger()
        )

        let record = try await importer.importImagePattern(data: SampleDataFactory.sampleImageData, fileName: "sample.png")

        XCTAssertNil(record.project.parts[0].rounds[0].atomicActions[0].instruction)
    }

    func testCrochetTermDictionaryClassifiesDescriptorsOutsideAtomicActionSet() {
        XCTAssertEqual(CrochetTermDictionary.definition(for: "sc")?.kind, .action)
        XCTAssertEqual(CrochetTermDictionary.definition(for: "fpdc")?.kind, .action)
        XCTAssertEqual(CrochetTermDictionary.definition(for: "flo")?.kind, .descriptor)
        XCTAssertEqual(CrochetTermDictionary.definition(for: "blo")?.kind, .descriptor)
        XCTAssertTrue(StitchActionType.sc.isAtomicActionType)
        XCTAssertTrue(StitchActionType.fpdc.isAtomicActionType)
        XCTAssertTrue(CrochetTermDictionary.supportedAtomicActionTypes.contains(.fpdc))
        XCTAssertFalse(StitchActionType.flo.isAtomicActionType)
        XCTAssertFalse(StitchActionType.blo.isAtomicActionType)
        XCTAssertFalse(StitchActionType.custom.isAtomicActionType)
    }

    func testImportImagePatternRejectsNonActionAtomicType() async throws {
        var imageResponse = SampleDataFactory.demoImageParseResponse
        imageResponse.parts[0].rounds[0].atomicActions[0].type = .flo

        let importer = PatternImportService(
            parserClient: FixturePatternParsingClient(
                outlineResponse: SampleDataFactory.demoOutlineResponse,
                imageResponse: imageResponse,
                atomizationResponse: SampleDataFactory.demoAtomizationResponse
            ),
            extractor: HTMLExtractionService(),
            logger: ConsoleTraceLogger()
        )

        do {
            _ = try await importer.importImagePattern(data: SampleDataFactory.sampleImageData, fileName: "sample.png")
            XCTFail("预期应拒绝非动作术语进入 atomicActions")
        } catch let error as PatternImportFailure {
            guard case let .invalidResponse(message) = error else {
                return XCTFail("收到错误类型不正确：\(error)")
            }
            XCTAssertEqual(message, "image_parse_contains_non_action_type:flo")
        }
    }

    func testOutlineLLMRequestUsesStrictJSONSchemaWithoutParseWarningsOrNotes() async throws {
        let capture = RequestCapture()
        let completionData = try completionResponseData(for: SampleDataFactory.demoOutlineResponse)
        MockURLProtocol.handler = { request in
            capture.body = try requestBody(from: request)
            let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, completionData)
        }

        let session = URLSession(configuration: configuration())
        let client = OpenAICompatibleLLMClient(
            configuration: try testConfiguration(),
            session: session,
            logger: ConsoleTraceLogger()
        )

        _ = try await client.parseTextPatternOutline(
            extractedText: "Body\nRound 1: In a MR, sc 6. (6)",
            titleHint: "Smoke",
            context: ParseRequestContext(traceID: "request-test-text", parseRequestID: "request-test-text", sourceType: .web)
        )

        let requestData = try XCTUnwrap(capture.body)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: requestData) as? [String: Any])
        XCTAssertEqual(object["model"] as? String, "text-model")
        XCTAssertNil(object["provider"])
        let responseFormat = try XCTUnwrap(object["response_format"] as? [String: Any])
        let jsonSchema = try XCTUnwrap(responseFormat["json_schema"] as? [String: Any])
        let schema = try XCTUnwrap(jsonSchema["schema"] as? [String: Any])
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        XCTAssertNil(properties["parseWarnings"])
        XCTAssertNil(properties["notes"])

        let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
        XCTAssertTrue((messages.first?["content"] as? String)?.contains("Do not generate atomicActions in this stage.") == true)
        XCTAssertFalse((messages.first?["content"] as? String)?.contains("parseWarnings") == true)
        XCTAssertFalse((messages.first?["content"] as? String)?.contains("- notes") == true)
    }

    func testAtomizationLLMRequestUsesStructuredSegmentSchema() async throws {
        let capture = RequestCapture()
        let completionData = try completionResponseData(for: SampleDataFactory.demoAtomizationResponse)
        MockURLProtocol.handler = { request in
            capture.body = try requestBody(from: request)
            let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, completionData)
        }

        let session = URLSession(configuration: configuration())
        let client = OpenAICompatibleLLMClient(
            configuration: try testConfiguration(),
            session: session,
            logger: ConsoleTraceLogger()
        )

        _ = try await client.atomizeTextRounds(
            projectTitle: "Mouse Cat Toy",
            materials: ["4.0 mm hook"],
            rounds: [
                AtomizationRoundInput(
                    partName: "Body",
                    title: "Round 1",
                    rawInstruction: "In a MR, sc 6. (6)",
                    summary: "Create a magic ring and crochet six single crochets into it.",
                    targetStitchCount: 6
                )
            ],
            context: ParseRequestContext(traceID: "request-atomize", parseRequestID: "request-atomize", sourceType: .web)
        )

        let requestData = try XCTUnwrap(capture.body)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: requestData) as? [String: Any])
        XCTAssertEqual(object["model"] as? String, "atomization-model")
        XCTAssertNil(object["provider"])
        let responseFormat = try XCTUnwrap(object["response_format"] as? [String: Any])
        let jsonSchema = try XCTUnwrap(responseFormat["json_schema"] as? [String: Any])
        let schema = try XCTUnwrap(jsonSchema["schema"] as? [String: Any])
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        let rounds = try XCTUnwrap(properties["rounds"] as? [String: Any])
        let roundItems = try XCTUnwrap(rounds["items"] as? [String: Any])
        let roundProperties = try XCTUnwrap(roundItems["properties"] as? [String: Any])
        let segments = try XCTUnwrap(roundProperties["segments"] as? [String: Any])
        let segmentItems = try XCTUnwrap(segments["items"] as? [String: Any])
        XCTAssertEqual(segmentItems["$ref"] as? String, "#/$defs/segment")

        let defs = try XCTUnwrap(schema["$defs"] as? [String: Any])
        let segment = try XCTUnwrap(defs["segment"] as? [String: Any])
        let segmentProperties = try XCTUnwrap(segment["properties"] as? [String: Any])
        let typeDefinition = try XCTUnwrap(segmentProperties["type"] as? [String: Any])
        let allowedTypeStrings = try extractNullableEnumStrings(from: typeDefinition)
        XCTAssertNotNil(segmentProperties["count"])
        XCTAssertNotNil(segmentProperties["note"])
        XCTAssertNotNil(segmentProperties["notePlacement"])
        XCTAssertNotNil(segmentProperties["verbatim"])
        XCTAssertNotNil(segmentProperties["times"])
        XCTAssertNotNil(segmentProperties["sequence"])
        XCTAssertNotNil(segmentProperties["controlKind"])
        let producedStitchesDefinition = try XCTUnwrap(segmentProperties["producedStitches"] as? [String: Any])
        XCTAssertEqual(producedStitchesDefinition["type"] as? String, "null")
        XCTAssertEqual(allowedTypeStrings, CrochetTermDictionary.supportedAtomicActionTypes.map(\.rawValue))
        XCTAssertTrue(try nullableEnumAllowsNull(from: typeDefinition))
        XCTAssertFalse(allowedTypeStrings.contains("blo"))
        XCTAssertFalse(allowedTypeStrings.contains("flo"))
        XCTAssertFalse(allowedTypeStrings.contains("custom"))

        let controlKindDefinition = try XCTUnwrap(segmentProperties["controlKind"] as? [String: Any])
        let controlKindStrings = try extractNullableEnumStrings(from: controlKindDefinition)
        XCTAssertEqual(controlKindStrings, ControlSegmentKind.allCases.map(\.rawValue))
        XCTAssertTrue(try nullableEnumAllowsNull(from: controlKindDefinition))

        let repeatSequenceSegment = try XCTUnwrap(defs["repeatSequenceSegment"] as? [String: Any])
        let repeatSequenceProperties = try XCTUnwrap(repeatSequenceSegment["properties"] as? [String: Any])
        let repeatSequenceKinds = try XCTUnwrap((repeatSequenceProperties["kind"] as? [String: Any])?["enum"] as? [String])
        XCTAssertEqual(repeatSequenceKinds, [AtomizedSegmentKind.stitchRun.rawValue, AtomizedSegmentKind.control.rawValue])

        let requestJSONString = String(decoding: requestData, as: UTF8.self)
        XCTAssertFalse(requestJSONString.contains("\"oneOf\""))

        let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
        let systemPrompt = messages.first?["content"] as? String
        let userPrompt = messages.last?["content"] as? String
        XCTAssertTrue(systemPrompt?.contains("structured summary segments") == true)
        XCTAssertTrue(systemPrompt?.contains("Compress consecutive identical stitches into one stitchRun.") == true)
        XCTAssertTrue(systemPrompt?.contains("control.kind must be exactly one enum value") == true)
        XCTAssertTrue(systemPrompt?.contains("notePlacement must never be null") == true)
        XCTAssertTrue(systemPrompt?.contains("producedStitches must be null") == true)
        XCTAssertTrue(systemPrompt?.contains("set it to null instead of omitting it") == true)
        XCTAssertTrue(systemPrompt?.contains("fpdc must stay fpdc") == true)
        XCTAssertTrue(systemPrompt?.contains("Use notePlacement=all") == true)
        XCTAssertTrue(systemPrompt?.contains("Raw instruction: \"With off white, ch 114\"") == true)
        XCTAssertTrue(systemPrompt?.contains("control is only for standalone control steps") == true)
        XCTAssertTrue(systemPrompt?.contains("Skipping stitches is NOT a control") == true)
        XCTAssertTrue(systemPrompt?.contains("stitchRun(type=skip, count=N)") == true)
        XCTAssertTrue(userPrompt?.contains("Input rounds JSON:") == true)
        XCTAssertTrue(userPrompt?.contains("\"rawInstruction\"") == true)
        XCTAssertFalse(userPrompt?.contains("Previous attempt failed validation.") == true)
        XCTAssertTrue(userPrompt?.contains("\"summary\"") == true)
        XCTAssertTrue(userPrompt?.contains("Create a magic ring and crochet six single crochets into it.") == true)
        XCTAssertFalse(userPrompt?.contains("\"notes\"") == true)
    }

    func testAtomizationLLMHTTPFailureIncludesProviderErrorDetails() async throws {
        let providerError = #"""
        {
          "error": {
            "message": "Provider returned error",
            "code": 400,
            "metadata": {
              "raw": "{\n  \"error\": {\n    \"message\": \"Invalid schema for response_format 'crochet_round_atomization_response': In context=('properties', 'sequence', 'items'), 'oneOf' is not permitted.\",\n    \"type\": \"invalid_request_error\",\n    \"param\": \"text.format.schema\",\n    \"code\": \"invalid_json_schema\"\n  }\n}",
              "provider_name": "Azure",
              "is_byok": false
            }
          }
        }
        """#

        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 400, httpVersion: nil, headerFields: nil)!
            return (response, Data(providerError.utf8))
        }

        let session = URLSession(configuration: configuration())
        let client = OpenAICompatibleLLMClient(
            configuration: try testConfiguration(),
            session: session,
            logger: ConsoleTraceLogger()
        )

        do {
            _ = try await client.atomizeTextRounds(
                projectTitle: "Quiet Tides Baby Blanket",
                materials: ["Off white yarn"],
                rounds: [
                    AtomizationRoundInput(
                        partName: "Main",
                        title: "Foundation",
                        rawInstruction: "Using off white yarn, chain 114.",
                        summary: "Create the foundation chain with off white yarn.",
                        targetStitchCount: nil
                    )
                ],
                context: ParseRequestContext(traceID: "request-atomize-400", parseRequestID: "request-atomize-400", sourceType: .web)
            )
            XCTFail("预期应透传 provider 返回的 400 错误")
        } catch let error as PatternImportFailure {
            guard case let .fetchFailed(statusCode, details) = error else {
                return XCTFail("收到错误类型不正确：\(error)")
            }
            XCTAssertEqual(statusCode, 400)
            XCTAssertTrue(details?.contains("Azure") == true)
            XCTAssertTrue(details?.contains("Invalid schema for response_format") == true)
            XCTAssertTrue(error.localizedDescription.contains("请求失败，状态码 400") == true)
        }
    }

    func testRoundAtomizationDecodeDefaultsNullNotePlacementOnStitchRuns() throws {
        let payload = #"""
        {
          "rounds": [
            {
              "segments": [
                {
                  "times": null,
                  "kind": "stitchRun",
                  "producedStitches": null,
                  "controlKind": null,
                  "notePlacement": null,
                  "instruction": null,
                  "note": null,
                  "count": 7,
                  "type": "sc",
                  "sequence": null,
                  "verbatim": "7sc"
                }
              ]
            }
          ]
        }
        """#

        let response = try JSONDecoder().decode(RoundAtomizationResponse.self, from: Data(payload.utf8))
        guard case let .stitchRun(segment)? = response.rounds.first?.segments.first else {
            return XCTFail("预期解码出 stitchRun segment")
        }

        XCTAssertEqual(segment.count, 7)
        XCTAssertEqual(segment.type, .sc)
        XCTAssertEqual(segment.notePlacement, .first)
    }

    func testDeepSeekTextLLMRequestOmitsProviderRoutingPayloadWhenDisabled() async throws {
        let capture = RequestCapture()
        let completionData = try completionResponseData(for: SampleDataFactory.demoOutlineResponse)
        MockURLProtocol.handler = { request in
            capture.body = try requestBody(from: request)
            let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, completionData)
        }

        let session = URLSession(configuration: configuration())
        let client = OpenAICompatibleLLMClient(
            configuration: try RuntimeConfiguration.load(values: [
                "OPENAI_API_KEY": "test-key",
                "OPENAI_BASE_URL": "https://example.com/openrouter/v1/",
                "TEXT_MODEL_ID": "deepseek/deepseek-v3.2",
                "ATOMIZATION_MODEL_ID": "atomization-model",
                "VISION_MODEL_ID": "vision-model"
            ]),
            session: session,
            logger: ConsoleTraceLogger()
        )

        _ = try await client.parseTextPatternOutline(
            extractedText: "Body\nRound 1: In a MR, sc 6. (6)",
            titleHint: "Smoke",
            context: ParseRequestContext(traceID: "request-test-deepseek", parseRequestID: "request-test-deepseek", sourceType: .web)
        )

        let requestData = try XCTUnwrap(capture.body)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: requestData) as? [String: Any])
        XCTAssertNil(object["provider"])
    }

    func testAtomizeRoundsRejectsNonActionTermTypes() async throws {
        let html = try fixture(named: "mouse-pattern", extension: "html")
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(html.utf8))
        }

        let importer = PatternImportService(
            parserClient: FixturePatternParsingClient(
                outlineResponse: SampleDataFactory.demoOutlineResponse,
                imageResponse: SampleDataFactory.demoImageParseResponse,
                atomizationResponse: RoundAtomizationResponse(
                    rounds: [
                        AtomizedPatternRound(actionGroups: [
                            ParsedActionGroup(type: .sc, count: 1, instruction: nil, producedStitches: nil, note: nil),
                            ParsedActionGroup(type: .custom, count: 1, instruction: "change to white yarn", producedStitches: 0, note: nil),
                            ParsedActionGroup(type: .inc, count: 1, instruction: nil, producedStitches: nil, note: "work this increase in the same st as the previous sc"),
                            ParsedActionGroup(type: .slSt, count: 1, instruction: nil, producedStitches: nil, note: nil)
                        ])
                    ]
                )
            ),
            extractor: HTMLExtractionService(),
            session: URLSession(configuration: configuration()),
            logger: ConsoleTraceLogger()
        )

        let record = try await importer.importWebPattern(from: "https://example.com/pattern")
        let target = try firstRoundReferences(in: record.project, count: 1)

        do {
            _ = try await importer.atomizeRounds(in: record.project, targets: target)
            XCTFail("预期应拒绝 non-action type")
        } catch let error as PatternImportFailure {
            guard case let .atomizationFailed(message) = error else {
                return XCTFail("收到错误类型不正确：\(error)")
            }
            XCTAssertEqual(message, "atomization_contains_non_action_type:custom")
        }
    }

    func testAtomizeRoundsPreservesSameStitchNoteOnOriginalAction() async throws {
        let outline = makeSingleRoundOutlineResponse(
            rawInstruction: "ch 1, sc, inc",
            summary: "Chain once, single crochet, then increase in the same stitch.",
            targetStitchCount: 3
        )

        // Simulate LLM incorrectly placing "same stitch" note on the sc action
        let importer = PatternImportService(
            parserClient: FixturePatternParsingClient(
                outlineResponse: outline,
                imageResponse: SampleDataFactory.demoImageParseResponse,
                atomizationResponse: RoundAtomizationResponse(
                    rounds: [
                        AtomizedPatternRound(actionGroups: [
                            ParsedActionGroup(type: .ch, count: 1, instruction: nil, producedStitches: nil, note: nil),
                            ParsedActionGroup(type: .sc, count: 1, instruction: nil, producedStitches: nil, note: "inc in the same stitch"),
                            ParsedActionGroup(type: .inc, count: 1, instruction: nil, producedStitches: nil, note: nil)
                        ])
                    ]
                )
            ),
            extractor: HTMLExtractionService(),
            session: URLSession(configuration: configuration()),
            logger: ConsoleTraceLogger()
        )

        let record = importer.makePreviewWebRecord(
            from: outline,
            source: PatternSource(
                type: .web,
                displayName: "Note Preservation",
                sourceURL: "https://example.com/pattern",
                fileName: nil,
                fileSizeBytes: nil,
                importedAt: .now
            )
        )
        let target = try firstRoundReferences(in: record.project, count: 1)
        let updates = try await importer.atomizeRounds(in: record.project, targets: target)
        let actions = try XCTUnwrap(updates.first?.atomicActions)

        XCTAssertEqual(actions.map(\.type), [.ch, .sc, .inc])
        XCTAssertNil(actions[0].note)
        XCTAssertEqual(actions[1].note, "inc in the same stitch")
        XCTAssertNil(actions[2].note)
    }

    func testAtomizeRoundsExpandsFoundationChainRunAndCopiesRunNoteToEveryAction() async throws {
        let outline = makeSingleRoundOutlineResponse(
            rawInstruction: "With off white, ch 114",
            summary: "Create the foundation chain with off white yarn.",
            targetStitchCount: nil
        )
        let importer = PatternImportService(
            parserClient: FixturePatternParsingClient(
                outlineResponse: outline,
                imageResponse: SampleDataFactory.demoImageParseResponse,
                atomizationResponse: RoundAtomizationResponse(
                    rounds: [
                        AtomizedPatternRound(segments: [
                            .stitchRun(
                                StitchRunSegment(
                                    type: .ch,
                                    count: 114,
                                    instruction: nil,
                                    producedStitches: nil,
                                    note: "with off white yarn",
                                    notePlacement: .all,
                                    verbatim: "With off white, ch 114"
                                )
                            )
                        ])
                    ]
                )
            ),
            extractor: HTMLExtractionService(),
            logger: ConsoleTraceLogger()
        )

        let record = importer.makePreviewWebRecord(
            from: outline,
            source: PatternSource(
                type: .text,
                displayName: "Foundation Chain",
                sourceURL: nil,
                fileName: nil,
                fileSizeBytes: nil,
                importedAt: .now
            )
        )
        let target = try firstRoundReferences(in: record.project, count: 1)
        let updates = try await importer.atomizeRounds(in: record.project, targets: target)
        let update = try XCTUnwrap(updates.first)

        XCTAssertEqual(update.atomicActions.count, 114)
        XCTAssertTrue(update.atomicActions.allSatisfy { $0.type == .ch })
        XCTAssertTrue(update.atomicActions.allSatisfy { $0.note == "with off white yarn" })
        XCTAssertEqual(update.resolvedStitchCount, 0)
    }

    func testAtomizeRoundsExpandsRowInstructionWithControlTurn() async throws {
        let outline = makeSingleRoundOutlineResponse(
            rawInstruction: "Row 1: 1 sc in the 2nd ch from the hook and in each ch across. (113 sc) Ch 1, turn.",
            summary: "Work 113 single crochets across, chain one, then turn.",
            targetStitchCount: 113
        )
        let importer = PatternImportService(
            parserClient: FixturePatternParsingClient(
                outlineResponse: outline,
                imageResponse: SampleDataFactory.demoImageParseResponse,
                atomizationResponse: RoundAtomizationResponse(
                    rounds: [
                        AtomizedPatternRound(segments: [
                            .stitchRun(
                                StitchRunSegment(
                                    type: .sc,
                                    count: 113,
                                    instruction: nil,
                                    producedStitches: nil,
                                    note: "in the 2nd ch from the hook",
                                    notePlacement: .first,
                                    verbatim: "1 sc in the 2nd ch from the hook and in each ch across"
                                )
                            ),
                            .stitchRun(
                                StitchRunSegment(
                                    type: .ch,
                                    count: 1,
                                    instruction: nil,
                                    producedStitches: nil,
                                    note: nil,
                                    notePlacement: .first,
                                    verbatim: "Ch 1"
                                )
                            ),
                            .control(
                                ControlSegment(
                                    kind: .turn,
                                    instruction: nil,
                                    note: nil,
                                    verbatim: "turn"
                                )
                            )
                        ])
                    ]
                )
            ),
            extractor: HTMLExtractionService(),
            logger: ConsoleTraceLogger()
        )

        let record = importer.makePreviewWebRecord(
            from: outline,
            source: PatternSource(
                type: .text,
                displayName: "Row Pattern",
                sourceURL: nil,
                fileName: nil,
                fileSizeBytes: nil,
                importedAt: .now
            )
        )
        let target = try firstRoundReferences(in: record.project, count: 1)
        let updates = try await importer.atomizeRounds(in: record.project, targets: target)
        let actions = try XCTUnwrap(updates.first?.atomicActions)

        XCTAssertEqual(actions.count, 115)
        XCTAssertEqual(actions.prefix(113).map(\.type), Array(repeating: .sc, count: 113))
        XCTAssertEqual(actions[0].note, "in the 2nd ch from the hook")
        XCTAssertNil(actions[1].note)
        XCTAssertEqual(actions[113].type, .ch)
        XCTAssertEqual(actions[114].type, .custom)
        XCTAssertEqual(actions[114].instruction, "turn")
        XCTAssertEqual(updates.first?.resolvedStitchCount, 113)
    }

    func testAtomizeRoundsAttachesTrailingColorChangeNoteToLastAction() async throws {
        let outline = makeSingleRoundOutlineResponse(
            rawInstruction: "R3: sc around (12), change color",
            summary: "Single crochet around and change color at the end.",
            targetStitchCount: 12
        )
        let importer = PatternImportService(
            parserClient: FixturePatternParsingClient(
                outlineResponse: outline,
                imageResponse: SampleDataFactory.demoImageParseResponse,
                atomizationResponse: RoundAtomizationResponse(
                    rounds: [
                        AtomizedPatternRound(segments: [
                            .stitchRun(
                                StitchRunSegment(
                                    type: .sc,
                                    count: 12,
                                    instruction: nil,
                                    producedStitches: nil,
                                    note: "change color",
                                    notePlacement: .last,
                                    verbatim: "sc around (12), change color"
                                )
                            )
                        ])
                    ]
                )
            ),
            extractor: HTMLExtractionService(),
            logger: ConsoleTraceLogger()
        )

        let record = importer.makePreviewWebRecord(
            from: outline,
            source: PatternSource(
                type: .text,
                displayName: "Color Change",
                sourceURL: nil,
                fileName: nil,
                fileSizeBytes: nil,
                importedAt: .now
            )
        )
        let target = try firstRoundReferences(in: record.project, count: 1)
        let updates = try await importer.atomizeRounds(in: record.project, targets: target)
        let actions = updates.first?.atomicActions

        XCTAssertEqual(actions?.count, 12)
        XCTAssertTrue(actions?.dropLast().allSatisfy { $0.note == nil } == true)
        XCTAssertEqual(actions?.last?.note, "change color")
    }

    func testAtomizeRoundsAttachesWholeRunContextNoteToEveryAction() async throws {
        let outline = makeSingleRoundOutlineResponse(
            rawInstruction: "R8: work in FLO of R5: sc 12",
            summary: "Work twelve single crochets in the front loop only of round five.",
            targetStitchCount: 12
        )
        let importer = PatternImportService(
            parserClient: FixturePatternParsingClient(
                outlineResponse: outline,
                imageResponse: SampleDataFactory.demoImageParseResponse,
                atomizationResponse: RoundAtomizationResponse(
                    rounds: [
                        AtomizedPatternRound(segments: [
                            .stitchRun(
                                StitchRunSegment(
                                    type: .sc,
                                    count: 12,
                                    instruction: nil,
                                    producedStitches: nil,
                                    note: "work in FLO of Round 5",
                                    notePlacement: .all,
                                    verbatim: "work in FLO of R5: sc 12"
                                )
                            )
                        ])
                    ]
                )
            ),
            extractor: HTMLExtractionService(),
            logger: ConsoleTraceLogger()
        )

        let record = importer.makePreviewWebRecord(
            from: outline,
            source: PatternSource(
                type: .text,
                displayName: "FLO Round",
                sourceURL: nil,
                fileName: nil,
                fileSizeBytes: nil,
                importedAt: .now
            )
        )
        let target = try firstRoundReferences(in: record.project, count: 1)
        let updates = try await importer.atomizeRounds(in: record.project, targets: target)
        let actions = updates.first?.atomicActions

        XCTAssertEqual(actions?.count, 12)
        XCTAssertTrue(actions?.allSatisfy { $0.note == "work in FLO of Round 5" } == true)
    }

    func testAtomizeRoundsPreservesFrontPostDoubleCrochetType() async throws {
        let outline = makeSingleRoundOutlineResponse(
            rawInstruction: "fpdc around next st",
            summary: "Work one front post double crochet around the next stitch.",
            targetStitchCount: 1
        )
        let importer = PatternImportService(
            parserClient: FixturePatternParsingClient(
                outlineResponse: outline,
                imageResponse: SampleDataFactory.demoImageParseResponse,
                atomizationResponse: RoundAtomizationResponse(
                    rounds: [
                        AtomizedPatternRound(segments: [
                            .stitchRun(
                                StitchRunSegment(
                                    type: .fpdc,
                                    count: 1,
                                    instruction: "fpdc around next st",
                                    producedStitches: nil,
                                    note: "around next stitch",
                                    notePlacement: .all,
                                    verbatim: "fpdc around next st"
                                )
                            )
                        ])
                    ]
                )
            ),
            extractor: HTMLExtractionService(),
            logger: ConsoleTraceLogger()
        )

        let record = importer.makePreviewWebRecord(
            from: outline,
            source: PatternSource(
                type: .text,
                displayName: "Post Stitch",
                sourceURL: nil,
                fileName: nil,
                fileSizeBytes: nil,
                importedAt: .now
            )
        )
        let target = try firstRoundReferences(in: record.project, count: 1)
        let actions = try await importer.atomizeRounds(in: record.project, targets: target).first?.atomicActions

        XCTAssertEqual(actions?.count, 1)
        XCTAssertEqual(actions?.first?.type, .fpdc)
        XCTAssertEqual(actions?.first?.producedStitches, 1)
        XCTAssertEqual(actions?.first?.note, "around next stitch")
        XCTAssertEqual(actions?.first?.instruction, "fpdc around next st")
    }

    func testAtomizeRoundsBackfillsMissingTargetStitchCountFromExpandedActions() async throws {
        let outline = makeSingleRoundOutlineResponse(
            rawInstruction: "sc 12",
            summary: "Single crochet twelve stitches.",
            targetStitchCount: nil
        )
        let importer = PatternImportService(
            parserClient: FixturePatternParsingClient(
                outlineResponse: outline,
                imageResponse: SampleDataFactory.demoImageParseResponse,
                atomizationResponse: RoundAtomizationResponse(
                    rounds: [
                        AtomizedPatternRound(segments: [
                            .stitchRun(
                                StitchRunSegment(
                                    type: .sc,
                                    count: 12,
                                    instruction: nil,
                                    producedStitches: nil,
                                    note: nil,
                                    notePlacement: .first,
                                    verbatim: "sc 12"
                                )
                            )
                        ])
                    ]
                )
            ),
            extractor: HTMLExtractionService(),
            logger: ConsoleTraceLogger()
        )

        let record = importer.makePreviewWebRecord(
            from: outline,
            source: PatternSource(
                type: .text,
                displayName: "Backfill Target",
                sourceURL: nil,
                fileName: nil,
                fileSizeBytes: nil,
                importedAt: .now
            )
        )
        let target = try firstRoundReferences(in: record.project, count: 1)
        let updates = try await importer.atomizeRounds(in: record.project, targets: target)
        let update = updates.first

        XCTAssertEqual(update?.resolvedStitchCount, 12)
    }

    func testAtomizeRoundsIgnoresModelProducedStitchesOverridesForDeterministicStitches() async throws {
        let outline = makeSingleRoundOutlineResponse(
            rawInstruction: "With grey yarn: Magic loop, ch1, 7sc, slst to the first sc.",
            summary: "Create a magic loop, chain one, work seven single crochets, then join.",
            targetStitchCount: 7
        )
        let importer = PatternImportService(
            parserClient: FixturePatternParsingClient(
                outlineResponse: outline,
                imageResponse: SampleDataFactory.demoImageParseResponse,
                atomizationResponse: RoundAtomizationResponse(
                    rounds: [
                        AtomizedPatternRound(segments: [
                            .stitchRun(
                                StitchRunSegment(
                                    type: .mr,
                                    count: 1,
                                    instruction: nil,
                                    producedStitches: 7,
                                    note: "with grey yarn",
                                    notePlacement: .all,
                                    verbatim: "With grey yarn: Magic loop"
                                )
                            ),
                            .stitchRun(
                                StitchRunSegment(
                                    type: .ch,
                                    count: 1,
                                    instruction: nil,
                                    producedStitches: 1,
                                    note: nil,
                                    notePlacement: .first,
                                    verbatim: "ch1"
                                )
                            ),
                            .stitchRun(
                                StitchRunSegment(
                                    type: .sc,
                                    count: 7,
                                    instruction: nil,
                                    producedStitches: 5,
                                    note: nil,
                                    notePlacement: .first,
                                    verbatim: "7sc"
                                )
                            ),
                            .stitchRun(
                                StitchRunSegment(
                                    type: .slSt,
                                    count: 1,
                                    instruction: nil,
                                    producedStitches: 4,
                                    note: "to the first sc",
                                    notePlacement: .all,
                                    verbatim: "slst to the first sc"
                                )
                            )
                        ])
                    ]
                )
            ),
            extractor: HTMLExtractionService(),
            logger: ConsoleTraceLogger()
        )

        let record = importer.makePreviewWebRecord(
            from: outline,
            source: PatternSource(
                type: .text,
                displayName: "Magic Loop",
                sourceURL: nil,
                fileName: nil,
                fileSizeBytes: nil,
                importedAt: .now
            )
        )
        let target = try firstRoundReferences(in: record.project, count: 1)
        let updates = try await importer.atomizeRounds(in: record.project, targets: target)
        let actions = try XCTUnwrap(updates.first?.atomicActions)

        XCTAssertEqual(actions.map(\.type), [.mr, .ch, .sc, .sc, .sc, .sc, .sc, .sc, .sc, .slSt])
        XCTAssertEqual(actions.reduce(0) { $0 + $1.producedStitches }, 7)
        XCTAssertEqual(updates.first?.resolvedStitchCount, 7)
    }

    func testAtomizeRoundsRejectsDescriptorTypeEvenWhenInstructionExists() async throws {
        let html = try fixture(named: "mouse-pattern", extension: "html")
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(html.utf8))
        }

        let importer = PatternImportService(
            parserClient: FixturePatternParsingClient(
                outlineResponse: SampleDataFactory.demoOutlineResponse,
                imageResponse: SampleDataFactory.demoImageParseResponse,
                atomizationResponse: RoundAtomizationResponse(
                    rounds: [
                        AtomizedPatternRound(actionGroups: [
                            ParsedActionGroup(type: .flo, count: 1, instruction: "front loop only", producedStitches: nil)
                        ])
                    ]
                )
            ),
            extractor: HTMLExtractionService(),
            session: URLSession(configuration: configuration()),
            logger: ConsoleTraceLogger()
        )

        let record = try await importer.importWebPattern(from: "https://example.com/pattern")
        let target = try firstRoundReferences(in: record.project, count: 1)

        do {
            _ = try await importer.atomizeRounds(in: record.project, targets: target)
            XCTFail("预期应拒绝描述性 type")
        } catch let error as PatternImportFailure {
            guard case let .atomizationFailed(message) = error else {
                return XCTFail("收到错误类型不正确：\(error)")
            }
            XCTAssertEqual(message, "atomization_contains_non_action_type:flo")
        }
    }

    func testRoundAtomizationDecodeRejectsUnsupportedActionType() throws {
        let data = Data("""
        {
          "rounds": [
            {
              "segments": [
                {
                  "kind": "stitchRun",
                  "type": "magic loop",
                  "count": 1,
                  "instruction": null,
                  "producedStitches": null,
                  "note": null,
                  "notePlacement": "first",
                  "verbatim": "magic loop"
                }
              ]
            }
          ]
        }
        """.utf8)

        XCTAssertThrowsError(try JSONDecoder().decode(RoundAtomizationResponse.self, from: data))
    }

    func testAtomizeRoundsUsesSingleModelResponseWithoutSemanticRetry() async throws {
        let parserClient = RetryingAtomizationClient(
            outlineResponse: PatternOutlineResponse(
                projectTitle: "Wolf Granny Square",
                materials: ["Grey yarn"],
                confidence: 0.99,
                parts: [
                    OutlinedPatternPart(
                        name: "Wolf Head",
                        rounds: [
                            OutlinedPatternRound(
                                title: "Round 1",
                                rawInstruction: "With grey yarn: Magic loop, ch1, 7sc, slst to the first sc.",
                                summary: "Create the first wolf head round.",
                                targetStitchCount: 7
                            )
                        ]
                    )
                ]
            ),
            responses: [
                .success(
                    RoundAtomizationResponse(rounds: [
                        AtomizedPatternRound(actionGroups: [
                            ParsedActionGroup(type: .custom, count: 1, instruction: "magic loop", producedStitches: 0, note: "With grey yarn."),
                            ParsedActionGroup(type: .ch, count: 1, instruction: nil, producedStitches: nil, note: nil),
                            ParsedActionGroup(type: .sc, count: 1, instruction: nil, producedStitches: nil, note: nil),
                            ParsedActionGroup(type: .sc, count: 1, instruction: nil, producedStitches: nil, note: nil),
                            ParsedActionGroup(type: .sc, count: 1, instruction: nil, producedStitches: nil, note: nil),
                            ParsedActionGroup(type: .sc, count: 1, instruction: nil, producedStitches: nil, note: nil),
                            ParsedActionGroup(type: .sc, count: 1, instruction: nil, producedStitches: nil, note: nil),
                            ParsedActionGroup(type: .sc, count: 1, instruction: nil, producedStitches: nil, note: nil),
                            ParsedActionGroup(type: .sc, count: 1, instruction: nil, producedStitches: nil, note: nil),
                            ParsedActionGroup(type: .slSt, count: 1, instruction: nil, producedStitches: nil, note: "Join to the first sc.")
                        ])
                    ])
                )
            ]
        )

        let importer = PatternImportService(
            parserClient: parserClient,
            extractor: HTMLExtractionService(),
            logger: ConsoleTraceLogger()
        )

        let record = importer.makePreviewWebRecord(
            from: await parserClient.outline(),
            source: PatternSource(
                type: .web,
                displayName: "Wolf",
                sourceURL: "https://grannysquare.me/wolf-granny-square/#pattern",
                fileName: nil,
                fileSizeBytes: nil,
                importedAt: .now
            )
        )
        let targets = try firstRoundReferences(in: record.project, count: 1)
        do {
            _ = try await importer.atomizeRounds(in: record.project, targets: targets)
            XCTFail("预期应直接暴露 non-action type，而不是做语义兜底")
        } catch let error as PatternImportFailure {
            guard case let .atomizationFailed(message) = error else {
                return XCTFail("收到错误类型不正确：\(error)")
            }
            XCTAssertEqual(message, "atomization_contains_non_action_type:custom")
        }

        let callCount = await parserClient.atomizationCallCount()
        XCTAssertEqual(callCount, 1)
    }

    func testTextLLMRepairsMalformedOutlineJSONResponse() async throws {
        let capture = RequestSequenceCapture()

        MockURLProtocol.handler = { [self, capture] request in
            capture.requestCount += 1
            capture.bodies.append(try requestBody(from: request))

            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!

            if capture.requestCount == 1 {
                let malformed = """
                {"projectTitle":"Mouse Cat Toy","materials":[],"confidence":0.91,"parts":[{"name":"Body","rounds":[{"title":"Round 1","rawInstruction":"In a MR, sc 6. (6)","summary":"Create a magic ring.","targetStitchCount":6}]}]
                """
                return (response, try self.completionResponseData(withContent: malformed))
            }

            return (response, try self.completionResponseData(for: SampleDataFactory.demoOutlineResponse))
        }

        let session = URLSession(configuration: configuration())
        let client = OpenAICompatibleLLMClient(
            configuration: try testConfiguration(),
            session: session,
            logger: ConsoleTraceLogger()
        )

        let response = try await client.parseTextPatternOutline(
            extractedText: "Body\nRound 1: In a MR, sc 6. (6)",
            titleHint: "Smoke",
            context: ParseRequestContext(traceID: "request-test-repair", parseRequestID: "request-test-repair", sourceType: .web)
        )

        XCTAssertEqual(capture.requestCount, 2)
        let requestObjects = try capture.bodies.map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: $0) as? [String: Any])
        }
        XCTAssertEqual(requestObjects.compactMap { $0["model"] as? String }, ["text-model", "text-model"])
        XCTAssertEqual(response.projectTitle, "Mouse Cat Toy")
    }

    func testAtomizationLLMRepairsMalformedJSONResponseWithAtomizationModel() async throws {
        let capture = RequestSequenceCapture()

        MockURLProtocol.handler = { [self, capture] request in
            capture.requestCount += 1
            capture.bodies.append(try requestBody(from: request))

            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!

            if capture.requestCount == 1 {
                let malformed = """
                {"rounds":[{"segments":[{"kind":"stitchRun","type":"mr","count":1,"instruction":"mr","producedStitches":0,"note":null,"notePlacement":"first","verbatim":"mr"}]}]
                """
                return (response, try self.completionResponseData(withContent: malformed))
            }

            return (response, try self.completionResponseData(for: SampleDataFactory.demoAtomizationResponse))
        }

        let session = URLSession(configuration: configuration())
        let client = OpenAICompatibleLLMClient(
            configuration: try testConfiguration(),
            session: session,
            logger: ConsoleTraceLogger()
        )

        let response = try await client.atomizeTextRounds(
            projectTitle: "Mouse Cat Toy",
            materials: ["4.0 mm hook"],
            rounds: [
                AtomizationRoundInput(
                    partName: "Body",
                    title: "Round 1",
                    rawInstruction: "In a MR, sc 6. (6)",
                    summary: "Create a magic ring and crochet six single crochets into it.",
                    targetStitchCount: 6
                )
            ],
            context: ParseRequestContext(traceID: "request-atomize-repair", parseRequestID: "request-atomize-repair", sourceType: .web)
        )

        XCTAssertEqual(capture.requestCount, 2)
        let requestObjects = try capture.bodies.map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: $0) as? [String: Any])
        }
        XCTAssertEqual(requestObjects.compactMap { $0["model"] as? String }, ["atomization-model", "atomization-model"])
        XCTAssertFalse(response.rounds.isEmpty)
    }

    func testImageLLMLogsRequestPayloadWithoutBase64DataURL() async throws {
        let eventCapture = EventCapture()
        let completionData = try completionResponseData(for: SampleDataFactory.demoImageParseResponse)
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, completionData)
        }

        let session = URLSession(configuration: configuration())
        let client = OpenAICompatibleLLMClient(
            configuration: try testConfiguration(),
            session: session,
            logger: ConsoleTraceLogger { eventCapture.events.append($0) }
        )

        _ = try await client.parseImagePattern(
            imageData: SampleDataFactory.sampleImageData,
            mimeType: "image/png",
            fileName: "sample.png",
            context: ParseRequestContext(traceID: "image-log-trace", parseRequestID: "image-log-parse", sourceType: .image)
        )

        let requestEvent = try XCTUnwrap(eventCapture.events.first(where: { $0.stage == "llm_request_payload" }))
        let requestJSON = try XCTUnwrap(requestEvent.metadata["requestJSON"])
        XCTAssertTrue(requestJSON.contains("[omitted data URL]"))
        XCTAssertFalse(requestJSON.contains("data:image/png;base64,"))
    }

    // MARK: - Macro-repeat expansion tests

    func testMacroRepeatExpandsFullCycles() async throws {
        let outlineResponse = PatternOutlineResponse(
            projectTitle: "Test",
            materials: [],
            confidence: 1.0,
            parts: [
                OutlinedPatternPart(
                    name: "Body",
                    rounds: [
                        OutlinedPatternRound(title: "Round 1", rawInstruction: "MR, sc 6. (6)", summary: "MR", targetStitchCount: 6),
                        OutlinedPatternRound(title: "Round 2", rawInstruction: "Inc x 6. (12)", summary: "Inc all", targetStitchCount: 12),
                        OutlinedPatternRound(title: "Round 3", rawInstruction: "(sc, inc) x 6. (18)", summary: "sc, inc repeat", targetStitchCount: 18),
                        OutlinedPatternRound(title: "Round 4", rawInstruction: "(sc 2, inc) x 6. (24)", summary: "sc 2, inc repeat", targetStitchCount: 24),
                        OutlinedPatternRound(
                            title: "Repeat Rounds 2-4",
                            rawInstruction: "Repeat Rounds 2-4 until you have 10 rounds total.",
                            summary: "Cycle through rounds 2-4 until 10 rounds.",
                            targetStitchCount: nil,
                            repeatFromTitle: "Round 2",
                            repeatToTitle: "Round 4",
                            repeatUntilCount: 10,
                            repeatAfterRow: 4
                        )
                    ]
                )
            ]
        )

        let parserClient = OutlineTextCaptureClient(response: outlineResponse)
        let importer = PatternImportService(
            parserClient: parserClient,
            extractor: HTMLExtractionService(),
            logger: ConsoleTraceLogger()
        )

        let record = try await importer.importTextPattern(from: "dummy")
        let rounds = record.project.parts.first!.rounds

        XCTAssertEqual(rounds.count, 10)
        // Round 5 = Round 2 pattern
        XCTAssertEqual(rounds[4].title, "Round 5")
        XCTAssertEqual(rounds[4].rawInstruction, "Inc x 6. (12)")
        XCTAssertEqual(rounds[4].targetStitchCount, 12)
        // Round 6 = Round 3 pattern
        XCTAssertEqual(rounds[5].title, "Round 6")
        XCTAssertEqual(rounds[5].rawInstruction, "(sc, inc) x 6. (18)")
        // Round 7 = Round 4 pattern
        XCTAssertEqual(rounds[6].title, "Round 7")
        XCTAssertEqual(rounds[6].rawInstruction, "(sc 2, inc) x 6. (24)")
        // Round 8 = Round 2 pattern (second cycle)
        XCTAssertEqual(rounds[7].title, "Round 8")
        XCTAssertEqual(rounds[7].rawInstruction, "Inc x 6. (12)")
        // Round 10 = Round 4 pattern (end of second cycle)
        XCTAssertEqual(rounds[9].title, "Round 10")
        XCTAssertEqual(rounds[9].rawInstruction, "(sc 2, inc) x 6. (24)")
        XCTAssertTrue(rounds.allSatisfy { $0.atomizationStatus == .pending })
    }

    func testMacroRepeatExpandsPartialCycle() async throws {
        let outlineResponse = PatternOutlineResponse(
            projectTitle: "Test",
            materials: [],
            confidence: 1.0,
            parts: [
                OutlinedPatternPart(
                    name: "Body",
                    rounds: [
                        OutlinedPatternRound(title: "Round 1", rawInstruction: "MR, sc 6.", summary: "MR", targetStitchCount: 6),
                        OutlinedPatternRound(title: "Round 2", rawInstruction: "Inc x 6.", summary: "Inc", targetStitchCount: 12),
                        OutlinedPatternRound(title: "Round 3", rawInstruction: "(sc, inc) x 6.", summary: "sc inc", targetStitchCount: 18),
                        OutlinedPatternRound(title: "Round 4", rawInstruction: "(sc 2, inc) x 6.", summary: "sc 2 inc", targetStitchCount: 24),
                        OutlinedPatternRound(title: "Round 5", rawInstruction: "sc around.", summary: "sc", targetStitchCount: 24),
                        OutlinedPatternRound(
                            title: "Repeat Rounds 3-5",
                            rawInstruction: "Repeat Rounds 3-5 until 12 rounds.",
                            summary: "Repeat 3-5.",
                            targetStitchCount: nil,
                            repeatFromTitle: "Round 3",
                            repeatToTitle: "Round 5",
                            repeatUntilCount: 12,
                            repeatAfterRow: 5
                        )
                    ]
                )
            ]
        )

        let parserClient = OutlineTextCaptureClient(response: outlineResponse)
        let importer = PatternImportService(
            parserClient: parserClient,
            extractor: HTMLExtractionService(),
            logger: ConsoleTraceLogger()
        )

        let record = try await importer.importTextPattern(from: "dummy")
        let rounds = record.project.parts.first!.rounds

        // 5 original + 7 expanded = 12 total
        // 7 = 2 full cycles (6) + 1 partial
        XCTAssertEqual(rounds.count, 12)
        // Round 6 = Round 3 pattern
        XCTAssertEqual(rounds[5].rawInstruction, "(sc, inc) x 6.")
        // Round 8 = Round 5 pattern (end of first cycle)
        XCTAssertEqual(rounds[7].rawInstruction, "sc around.")
        // Round 12 = Round 3 pattern (partial last cycle, only 1 round)
        XCTAssertEqual(rounds[11].title, "Round 12")
        XCTAssertEqual(rounds[11].rawInstruction, "(sc, inc) x 6.")
    }

    func testMacroRepeatQuietTidesScenario() async throws {
        // Simulate Quiet Tides Baby Blanket: Rows 1-13, repeat 6-13 until 118, then extra rows
        var rounds: [OutlinedPatternRound] = []
        for i in 1...13 {
            rounds.append(OutlinedPatternRound(
                title: "Row \(i)",
                rawInstruction: "Row \(i) instruction",
                summary: "Row \(i) summary",
                targetStitchCount: i * 10
            ))
        }
        rounds.append(OutlinedPatternRound(
            title: "Repeat Rows 6-13",
            rawInstruction: "Repeat Rows 6-13 until you have a total of 118 rows.",
            summary: "Cycle through rows 6-13 until 118 total rows.",
            targetStitchCount: nil,
            repeatFromTitle: "Row 6",
            repeatToTitle: "Row 13",
            repeatUntilCount: 118,
            repeatAfterRow: 13
        ))
        rounds.append(OutlinedPatternRound(
            title: "Row 119",
            rawInstruction: "Ch 1, turn, do one more row of sc.",
            summary: "One final sc row.",
            targetStitchCount: 130
        ))
        rounds.append(OutlinedPatternRound(
            title: "Weave in ends",
            rawInstruction: "Weave in ends, then move on to the border.",
            summary: "Finish main blanket.",
            targetStitchCount: nil
        ))

        let outlineResponse = PatternOutlineResponse(
            projectTitle: "Quiet Tides Baby Blanket",
            materials: [],
            confidence: 0.9,
            parts: [
                OutlinedPatternPart(name: "Main Blanket", rounds: rounds)
            ]
        )

        let parserClient = OutlineTextCaptureClient(response: outlineResponse)
        let importer = PatternImportService(
            parserClient: parserClient,
            extractor: HTMLExtractionService(),
            logger: ConsoleTraceLogger()
        )

        let record = try await importer.importTextPattern(from: "dummy")
        let resultRounds = record.project.parts.first!.rounds

        // 118 expanded rows + Row 119 + Weave in ends = 120 total
        XCTAssertEqual(resultRounds.count, 120)

        // Row 14 should copy Row 6's instruction
        XCTAssertEqual(resultRounds[13].title, "Row 14")
        XCTAssertEqual(resultRounds[13].rawInstruction, "Row 6 instruction")
        XCTAssertEqual(resultRounds[13].targetStitchCount, 60)

        // Row 21 should copy Row 13's instruction (end of 1st cycle)
        XCTAssertEqual(resultRounds[20].title, "Row 21")
        XCTAssertEqual(resultRounds[20].rawInstruction, "Row 13 instruction")

        // Row 118 should copy Row 6's instruction (partial last cycle)
        XCTAssertEqual(resultRounds[117].title, "Row 118")
        XCTAssertEqual(resultRounds[117].rawInstruction, "Row 6 instruction")

        // Row 119 is the extra sc row
        XCTAssertEqual(resultRounds[118].title, "Row 119")
        XCTAssertEqual(resultRounds[118].rawInstruction, "Ch 1, turn, do one more row of sc.")

        // Last round is "Weave in ends"
        XCTAssertEqual(resultRounds[119].title, "Weave in ends")
        XCTAssertEqual(resultRounds[119].rawInstruction, "Weave in ends, then move on to the border.")
    }

    func testMacroRepeatPreservesTrailingRounds() async throws {
        let outlineResponse = PatternOutlineResponse(
            projectTitle: "Test",
            materials: [],
            confidence: 1.0,
            parts: [
                OutlinedPatternPart(
                    name: "Body",
                    rounds: [
                        OutlinedPatternRound(title: "Round 1", rawInstruction: "MR, sc 6.", summary: "MR", targetStitchCount: 6),
                        OutlinedPatternRound(title: "Round 2", rawInstruction: "Inc x 6.", summary: "Inc", targetStitchCount: 12),
                        OutlinedPatternRound(title: "Round 3", rawInstruction: "sc around.", summary: "sc", targetStitchCount: 12),
                        OutlinedPatternRound(
                            title: "Repeat Rounds 2-3",
                            rawInstruction: "Repeat Rounds 2-3 until 7 rounds.",
                            summary: "Repeat 2-3.",
                            targetStitchCount: nil,
                            repeatFromTitle: "Round 2",
                            repeatToTitle: "Round 3",
                            repeatUntilCount: 7,
                            repeatAfterRow: 3
                        ),
                        OutlinedPatternRound(title: "Add stuffing", rawInstruction: "Add stuffing.", summary: "Stuff the body.", targetStitchCount: nil)
                    ]
                )
            ]
        )

        let parserClient = OutlineTextCaptureClient(response: outlineResponse)
        let importer = PatternImportService(
            parserClient: parserClient,
            extractor: HTMLExtractionService(),
            logger: ConsoleTraceLogger()
        )

        let record = try await importer.importTextPattern(from: "dummy")
        let rounds = record.project.parts.first!.rounds

        // 7 expanded rounds + 1 "Add stuffing" = 8 total
        XCTAssertEqual(rounds.count, 8)
        XCTAssertEqual(rounds[6].title, "Round 7")
        XCTAssertEqual(rounds[7].title, "Add stuffing")
        XCTAssertEqual(rounds[7].rawInstruction, "Add stuffing.")
    }

    func testMacroRepeatFallsBackWhenSourceRoundsNotFound() async throws {
        let outlineResponse = PatternOutlineResponse(
            projectTitle: "Test",
            materials: [],
            confidence: 1.0,
            parts: [
                OutlinedPatternPart(
                    name: "Body",
                    rounds: [
                        OutlinedPatternRound(title: "Round 1", rawInstruction: "MR, sc 6.", summary: "MR", targetStitchCount: 6),
                        OutlinedPatternRound(title: "Round 2", rawInstruction: "Inc x 6.", summary: "Inc", targetStitchCount: 12),
                        OutlinedPatternRound(title: "Round 3", rawInstruction: "sc around.", summary: "sc", targetStitchCount: 12),
                        OutlinedPatternRound(
                            title: "Repeat Rows 99-100",
                            rawInstruction: "Repeat Rows 99-100 until 20 rounds.",
                            summary: "Repeat.",
                            targetStitchCount: nil,
                            repeatFromTitle: "Row 99",
                            repeatToTitle: "Row 100",
                            repeatUntilCount: 20,
                            repeatAfterRow: 3
                        )
                    ]
                )
            ]
        )

        let parserClient = OutlineTextCaptureClient(response: outlineResponse)
        let importer = PatternImportService(
            parserClient: parserClient,
            extractor: HTMLExtractionService(),
            logger: ConsoleTraceLogger()
        )

        let record = try await importer.importTextPattern(from: "dummy")
        let rounds = record.project.parts.first!.rounds

        // Graceful degradation: sentinel becomes a regular round, total = 4
        XCTAssertEqual(rounds.count, 4)
        XCTAssertEqual(rounds[3].title, "Repeat Rows 99-100")
        XCTAssertEqual(rounds[3].rawInstruction, "Repeat Rows 99-100 until 20 rounds.")
    }

    func testMacroRepeatSkipsWhenAlreadyPastTarget() async throws {
        var rounds: [OutlinedPatternRound] = []
        for i in 1...10 {
            rounds.append(OutlinedPatternRound(
                title: "Round \(i)",
                rawInstruction: "Round \(i) instruction.",
                summary: "Round \(i).",
                targetStitchCount: i * 6
            ))
        }
        rounds.append(OutlinedPatternRound(
            title: "Repeat Rounds 2-5",
            rawInstruction: "Repeat Rounds 2-5 until 8 rounds.",
            summary: "Repeat.",
            targetStitchCount: nil,
            repeatFromTitle: "Round 2",
            repeatToTitle: "Round 5",
            repeatUntilCount: 8,
            repeatAfterRow: 10
        ))

        let outlineResponse = PatternOutlineResponse(
            projectTitle: "Test",
            materials: [],
            confidence: 1.0,
            parts: [
                OutlinedPatternPart(name: "Body", rounds: rounds)
            ]
        )

        let parserClient = OutlineTextCaptureClient(response: outlineResponse)
        let importer = PatternImportService(
            parserClient: parserClient,
            extractor: HTMLExtractionService(),
            logger: ConsoleTraceLogger()
        )

        let record = try await importer.importTextPattern(from: "dummy")
        let resultRounds = record.project.parts.first!.rounds

        // repeatAfterRow=10 > repeatUntilCount=8, sentinel degrades to regular round
        XCTAssertEqual(resultRounds.count, 11)
        XCTAssertEqual(resultRounds[10].title, "Repeat Rounds 2-5")
    }

    func testMacroRepeatTitleNumberReplacement() {
        // "Row 6" → "Row 14"
        XCTAssertEqual(
            PatternImportService.replaceTrailingNumber(in: "Row 6", with: 14),
            "Row 14"
        )
        // "Round 13" → "Round 21"
        XCTAssertEqual(
            PatternImportService.replaceTrailingNumber(in: "Round 13", with: 21),
            "Round 21"
        )
        // "Rnd 2" → "Rnd 5"
        XCTAssertEqual(
            PatternImportService.replaceTrailingNumber(in: "Rnd 2", with: 5),
            "Rnd 5"
        )
        // No digits → append
        XCTAssertEqual(
            PatternImportService.replaceTrailingNumber(in: "Add stuffing", with: 10),
            "Add stuffing 10"
        )
    }

    // MARK: - Macro-repeat repeatAfterRow tests

    func testMacroRepeatWithFoundationChainUsesRepeatAfterRow() async throws {
        // Foundation Chain (non-numbered) + Round 1-4 + sentinel with repeatAfterRow: 4
        let outlineResponse = PatternOutlineResponse(
            projectTitle: "Test",
            materials: [],
            confidence: 1.0,
            parts: [
                OutlinedPatternPart(
                    name: "Body",
                    rounds: [
                        OutlinedPatternRound(title: "Foundation Chain", rawInstruction: "Ch 114.", summary: "Chain 114.", targetStitchCount: nil),
                        OutlinedPatternRound(title: "Round 1", rawInstruction: "Sc across. (113)", summary: "sc across", targetStitchCount: 113),
                        OutlinedPatternRound(title: "Round 2", rawInstruction: "Inc x 6. (12)", summary: "Inc", targetStitchCount: 12),
                        OutlinedPatternRound(title: "Round 3", rawInstruction: "(sc, inc) x 6. (18)", summary: "sc inc", targetStitchCount: 18),
                        OutlinedPatternRound(title: "Round 4", rawInstruction: "(sc 2, inc) x 6. (24)", summary: "sc 2 inc", targetStitchCount: 24),
                        OutlinedPatternRound(
                            title: "Repeat Rounds 2-4",
                            rawInstruction: "Repeat Rounds 2-4 until 10 rounds.",
                            summary: "Repeat.",
                            targetStitchCount: nil,
                            repeatFromTitle: "Round 2",
                            repeatToTitle: "Round 4",
                            repeatUntilCount: 10,
                            repeatAfterRow: 4
                        )
                    ]
                )
            ]
        )

        let parserClient = OutlineTextCaptureClient(response: outlineResponse)
        let importer = PatternImportService(
            parserClient: parserClient,
            extractor: HTMLExtractionService(),
            logger: ConsoleTraceLogger()
        )

        let record = try await importer.importTextPattern(from: "dummy")
        let rounds = record.project.parts.first!.rounds

        // Foundation Chain + 4 original + 6 expanded = 11 round objects
        // repeatAfterRow=4, needed=10-4=6 expanded rounds
        XCTAssertEqual(rounds.count, 11)
        // First round is Foundation Chain
        XCTAssertEqual(rounds[0].title, "Foundation Chain")
        // Round 5 = Round 2 pattern (first expanded)
        XCTAssertEqual(rounds[5].title, "Round 5")
        XCTAssertEqual(rounds[5].rawInstruction, "Inc x 6. (12)")
        // Round 10 = Round 4 pattern (last expanded)
        XCTAssertEqual(rounds[10].title, "Round 10")
        XCTAssertEqual(rounds[10].rawInstruction, "(sc 2, inc) x 6. (24)")
    }

    func testMacroRepeatWithExtraRowBeforeRepeat() async throws {
        // Row 1-13, then Row 14 (extra, outside cycle), then repeat 6-13 until 118
        var rounds: [OutlinedPatternRound] = []
        for i in 1...14 {
            rounds.append(OutlinedPatternRound(
                title: "Row \(i)",
                rawInstruction: "Row \(i) instruction",
                summary: "Row \(i) summary",
                targetStitchCount: i * 10
            ))
        }
        rounds.append(OutlinedPatternRound(
            title: "Repeat Rows 6-13",
            rawInstruction: "Repeat Rows 6-13 until 118 rows.",
            summary: "Repeat.",
            targetStitchCount: nil,
            repeatFromTitle: "Row 6",
            repeatToTitle: "Row 13",
            repeatUntilCount: 118,
            repeatAfterRow: 14
        ))

        let outlineResponse = PatternOutlineResponse(
            projectTitle: "Test",
            materials: [],
            confidence: 1.0,
            parts: [
                OutlinedPatternPart(name: "Body", rounds: rounds)
            ]
        )

        let parserClient = OutlineTextCaptureClient(response: outlineResponse)
        let importer = PatternImportService(
            parserClient: parserClient,
            extractor: HTMLExtractionService(),
            logger: ConsoleTraceLogger()
        )

        let record = try await importer.importTextPattern(from: "dummy")
        let resultRounds = record.project.parts.first!.rounds

        // 14 original + 104 expanded (118-14) = 118 total
        XCTAssertEqual(resultRounds.count, 118)
        // Row 15 = Row 6 pattern (first expanded)
        XCTAssertEqual(resultRounds[14].title, "Row 15")
        XCTAssertEqual(resultRounds[14].rawInstruction, "Row 6 instruction")
        // Row 118 = last expanded
        XCTAssertEqual(resultRounds[117].title, "Row 118")
    }

    func testMacroRepeatFallsBackToResultCountWhenRepeatAfterRowNil() async throws {
        // Same as testMacroRepeatExpandsFullCycles but without repeatAfterRow
        let outlineResponse = PatternOutlineResponse(
            projectTitle: "Test",
            materials: [],
            confidence: 1.0,
            parts: [
                OutlinedPatternPart(
                    name: "Body",
                    rounds: [
                        OutlinedPatternRound(title: "Round 1", rawInstruction: "MR, sc 6.", summary: "MR", targetStitchCount: 6),
                        OutlinedPatternRound(title: "Round 2", rawInstruction: "Inc x 6.", summary: "Inc", targetStitchCount: 12),
                        OutlinedPatternRound(title: "Round 3", rawInstruction: "(sc, inc) x 6.", summary: "sc inc", targetStitchCount: 18),
                        OutlinedPatternRound(title: "Round 4", rawInstruction: "(sc 2, inc) x 6.", summary: "sc 2 inc", targetStitchCount: 24),
                        OutlinedPatternRound(
                            title: "Repeat Rounds 2-4",
                            rawInstruction: "Repeat Rounds 2-4 until 10 rounds.",
                            summary: "Repeat.",
                            targetStitchCount: nil,
                            repeatFromTitle: "Round 2",
                            repeatToTitle: "Round 4",
                            repeatUntilCount: 10
                            // repeatAfterRow is nil (default)
                        )
                    ]
                )
            ]
        )

        let parserClient = OutlineTextCaptureClient(response: outlineResponse)
        let importer = PatternImportService(
            parserClient: parserClient,
            extractor: HTMLExtractionService(),
            logger: ConsoleTraceLogger()
        )

        let record = try await importer.importTextPattern(from: "dummy")
        let rounds = record.project.parts.first!.rounds

        // Fallback to result.count=4, needed=10-4=6, total=10
        XCTAssertEqual(rounds.count, 10)
        XCTAssertEqual(rounds[4].title, "Round 5")
        XCTAssertEqual(rounds[4].rawInstruction, "Inc x 6.")
        XCTAssertEqual(rounds[9].title, "Round 10")
    }

    private func firstRoundReferences(in project: CrochetProject, count: Int) throws -> [RoundReference] {
        let references = project.parts.flatMap { part in
            part.rounds.map { RoundReference(partID: part.id, roundID: $0.id) }
        }
        return Array(references.prefix(count))
    }

    private func makeSingleRoundOutlineResponse(
        rawInstruction: String,
        summary: String,
        targetStitchCount: Int?
    ) -> PatternOutlineResponse {
        PatternOutlineResponse(
            projectTitle: "Custom Round",
            materials: ["Cotton yarn"],
            confidence: 1,
            parts: [
                OutlinedPatternPart(
                    name: "Body",
                    rounds: [
                        OutlinedPatternRound(
                            title: "Round 1",
                            rawInstruction: rawInstruction,
                            summary: summary,
                            targetStitchCount: targetStitchCount
                        )
                    ]
                )
            ]
        )
    }

    private func fixture(named name: String, extension fileExtension: String) throws -> String {
        let bundle = Bundle(for: Self.self)
        let url = try XCTUnwrap(bundle.url(forResource: name, withExtension: fileExtension))
        return try String(contentsOf: url)
    }

    private func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return configuration
    }

    private func completionResponseData<T: Encodable>(for payload: T) throws -> Data {
        let contentData = try JSONEncoder().encode(payload)
        let content = try XCTUnwrap(String(data: contentData, encoding: .utf8))
        return try completionResponseData(withContent: content)
    }

    private func completionResponseData(withContent content: String) throws -> Data {
        let object: [String: Any] = [
            "choices": [
                [
                    "message": [
                        "content": content
                    ]
                ]
            ]
        ]
        return try JSONSerialization.data(withJSONObject: object)
    }

    private func testConfiguration() throws -> RuntimeConfiguration {
        try RuntimeConfiguration.load(values: [
            "OPENAI_API_KEY": "test-key",
            "OPENAI_BASE_URL": "https://example.com/openrouter/v1/",
            "TEXT_MODEL_ID": "text-model",
            "ATOMIZATION_MODEL_ID": "atomization-model",
            "VISION_MODEL_ID": "vision-model"
        ])
    }
}

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    static var handler: @Sendable (URLRequest) throws -> (HTTPURLResponse, Data) = { _ in
        throw URLError(.badServerResponse)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "example.com"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let (response, data) = try Self.handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class RequestCapture: @unchecked Sendable {
    var body: Data?
}

private final class RequestSequenceCapture: @unchecked Sendable {
    var bodies: [Data] = []
    var requestCount = 0
}

private final class EventCapture: @unchecked Sendable {
    var events: [LogEvent] = []
}

private actor OutlineTextCaptureClient: PatternLLMParsing {
    private let response: PatternOutlineResponse
    private var extractedText: String?
    private var titleHint: String?
    private var context: ParseRequestContext?

    init(response: PatternOutlineResponse) {
        self.response = response
    }

    func parseTextPatternOutline(
        extractedText: String,
        titleHint: String?,
        context: ParseRequestContext
    ) async throws -> PatternOutlineResponse {
        self.extractedText = extractedText
        self.titleHint = titleHint
        self.context = context
        return response
    }

    func atomizeTextRounds(
        projectTitle: String,
        materials: [String],
        rounds: [AtomizationRoundInput],
        context: ParseRequestContext
    ) async throws -> RoundAtomizationResponse {
        SampleDataFactory.demoAtomizationResponse
    }

    func parseImagePattern(
        imageData: Data,
        mimeType: String,
        fileName: String,
        context: ParseRequestContext
    ) async throws -> PatternParseResponse {
        SampleDataFactory.demoImageParseResponse
    }

    func capturedTextRequest() -> (extractedText: String?, titleHint: String?, context: ParseRequestContext?) {
        (extractedText, titleHint, context)
    }
}

private actor AtomizationInputCaptureClient: PatternLLMParsing {
    private let outlineResponse: PatternOutlineResponse
    private let atomizationResponse: RoundAtomizationResponse
    private var lastRounds: [AtomizationRoundInput] = []

    init(outlineResponse: PatternOutlineResponse, atomizationResponse: RoundAtomizationResponse) {
        self.outlineResponse = outlineResponse
        self.atomizationResponse = atomizationResponse
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
        lastRounds = rounds
        return RoundAtomizationResponse(rounds: Array(atomizationResponse.rounds.prefix(rounds.count)))
    }

    func parseImagePattern(
        imageData: Data,
        mimeType: String,
        fileName: String,
        context: ParseRequestContext
    ) async throws -> PatternParseResponse {
        SampleDataFactory.demoImageParseResponse
    }

    func capturedRounds() -> [AtomizationRoundInput] {
        lastRounds
    }
}

private actor RetryingAtomizationClient: PatternLLMParsing {
    private let outlineResponse: PatternOutlineResponse
    private var responses: [Result<RoundAtomizationResponse, Error>]
    private var callCount = 0

    init(outlineResponse: PatternOutlineResponse, responses: [Result<RoundAtomizationResponse, Error>]) {
        self.outlineResponse = outlineResponse
        self.responses = responses
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
        callCount += 1
        guard !responses.isEmpty else {
            throw PatternImportFailure.atomizationFailed("missing_stub_response")
        }
        let result = responses.removeFirst()
        return try result.get()
    }

    func parseImagePattern(
        imageData: Data,
        mimeType: String,
        fileName: String,
        context: ParseRequestContext
    ) async throws -> PatternParseResponse {
        SampleDataFactory.demoImageParseResponse
    }

    func atomizationCallCount() -> Int {
        callCount
    }

    func outline() -> PatternOutlineResponse {
        outlineResponse
    }
}

private extension PatternImportService {
    func makePreviewWebRecord(from payload: PatternOutlineResponse, source: PatternSource) -> ProjectRecord {
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
            createdAt: .now,
            updatedAt: .now
        )

        return ProjectRecord(project: project, progress: .initial(for: project))
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: () async throws -> T,
    _ errorHandler: (Error) -> Void = { _ in },
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error to be thrown", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}

private func requestBody(from request: URLRequest) throws -> Data {
    if let body = request.httpBody {
        return body
    }

    guard let stream = request.httpBodyStream else {
        throw URLError(.badServerResponse)
    }

    stream.open()
    defer { stream.close() }

    let bufferSize = 4096
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
    defer { buffer.deallocate() }

    var data = Data()
    while stream.hasBytesAvailable {
        let read = stream.read(buffer, maxLength: bufferSize)
        if read < 0 {
            throw stream.streamError ?? URLError(.cannotParseResponse)
        }
        if read == 0 {
            break
        }
        data.append(buffer, count: read)
    }
    return data
}
