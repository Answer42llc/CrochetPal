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
                irResponse: SampleDataFactory.demoIRAtomizationResponse
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
                irResponse: SampleDataFactory.demoIRAtomizationResponse
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

    func testImportImagePatternUsesFixtureClient() async throws {
        let importer = PatternImportService(
            parserClient: FixturePatternParsingClient(
                outlineResponse: SampleDataFactory.demoOutlineResponse,
                imageResponse: SampleDataFactory.demoImageParseResponse,
                irResponse: SampleDataFactory.demoIRAtomizationResponse
            ),
            extractor: HTMLExtractionService(),
            logger: ConsoleTraceLogger()
        )

        let record = try await importer.importImagePattern(data: SampleDataFactory.sampleImageData, fileName: "sample.png")

        XCTAssertEqual(record.project.source.type, PatternSourceType.image)
        XCTAssertEqual(record.project.totalAtomicActionCount, 26)
        XCTAssertTrue(record.project.parts.flatMap(\.rounds).allSatisfy { $0.atomizationStatus == .ready })
    }

    func testImportImagePatternPreservesRawModelNote() async throws {
        var imageResponse = SampleDataFactory.demoImageParseResponse
        imageResponse.parts[0].rounds[0].atomicActions[0].note = "in a MR"

        let importer = PatternImportService(
            parserClient: FixturePatternParsingClient(
                outlineResponse: SampleDataFactory.demoOutlineResponse,
                imageResponse: imageResponse,
                irResponse: SampleDataFactory.demoIRAtomizationResponse
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
                irResponse: SampleDataFactory.demoIRAtomizationResponse
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
                irResponse: SampleDataFactory.demoIRAtomizationResponse
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


    // MARK: - Crochet IR compiler tests

    func testCrochetIRCompilerExpandsRepeatWithLastIterationOverride() throws {
        let repeatBody: [CrochetIRNode] = [
            .stitch(CrochetIRStitch(type: .dc, count: 2, note: "dc inc", notePlacement: .all, sourceText: "dc inc")),
            .stitch(CrochetIRStitch(type: .hdc, count: 8, sourceText: "8hdc")),
            .stitch(CrochetIRStitch(type: .dc, count: 2, note: "dc inc", notePlacement: .all, sourceText: "dc inc")),
            .stitch(CrochetIRStitch(type: .ch, count: 3, sourceText: "ch3"))
        ]
        let block = CrochetIRInstructionBlock(
            title: "Squaring",
            sourceText: "[dc inc, 8hdc, dc inc, ch3] repeat 3 times, omit the final ch3. Instead, work ch1, then 1hdc into the top of the first ch3.",
            expectedProducedStitches: 37,
            nodes: [
                .repeatBlock(CrochetIRRepeat(
                    times: 3,
                    body: repeatBody,
                    lastIterationTransform: CrochetIRRepeatLastIterationTransform(
                        removeTailNodeCount: 1,
                        append: [
                            .stitch(CrochetIRStitch(type: .ch, count: 1, sourceText: "ch1")),
                            .stitch(CrochetIRStitch(
                                type: .hdc,
                                count: 1,
                                note: "into the top of the first ch3",
                                notePlacement: .all,
                                sourceText: "1hdc into the top of the first ch3"
                            ))
                        ],
                        sourceText: "omit the final ch3"
                    ),
                    sourceText: "[dc inc, 8hdc, dc inc, ch3] repeat 3 times"
                ))
            ]
        )

        let expansion = try CrochetIRCompiler().expand(block)

        XCTAssertEqual(expansion.atomicActions.count, 44)
        XCTAssertEqual(expansion.producedStitchCount, 37)
        XCTAssertEqual(expansion.atomicActions.suffix(2).map(\.type), [.ch, .hdc])
        XCTAssertEqual(expansion.atomicActions.last?.note, "into the top of the first ch3")
        XCTAssertTrue(expansion.warnings.isEmpty)
    }

    func testCrochetIRCompilerHandlesConditionalChoiceAndCommonBody() throws {
        let commonBody: [CrochetIRNode] = [
            .repeatBlock(CrochetIRRepeat(
                times: 2,
                body: [
                    .stitch(CrochetIRStitch(type: .ch, count: 3)),
                    .stitch(CrochetIRStitch(type: .fpsc, count: 1, note: "around next Popcorn", notePlacement: .all)),
                    .stitch(CrochetIRStitch(type: .ch, count: 3)),
                    .stitch(CrochetIRStitch(type: .fpdc, count: 1, note: "around next FPhdc", notePlacement: .all))
                ],
                lastIterationTransform: CrochetIRRepeatLastIterationTransform(removeTailNodeCount: 1)
            ))
        ]
        let block = CrochetIRInstructionBlock(
            title: "Round 5",
            sourceText: "If using a different colour start with standing FPdc. If using the same colour start with fake FPdc.",
            nodes: [
                .conditional(CrochetIRConditional(
                    choiceID: "colour_mode",
                    question: "Are you using a different colour for this round?",
                    branches: [
                        CrochetIRConditionalBranch(
                            value: "different_colour",
                            label: "Different colour",
                            nodes: [.stitch(CrochetIRStitch(type: .fpdc, count: 1, note: "standing FPdc", notePlacement: .all))]
                        ),
                        CrochetIRConditionalBranch(
                            value: "same_colour",
                            label: "Same colour",
                            nodes: [
                                .stitch(CrochetIRStitch(type: .fpsc, count: 1)),
                                .stitch(CrochetIRStitch(type: .ch, count: 1)),
                                .stitch(CrochetIRStitch(type: .sc, count: 1, note: "counts as fake FPdc", notePlacement: .all))
                            ]
                        )
                    ],
                    commonBody: commonBody
                ))
            ]
        )

        let expansion = try CrochetIRCompiler().expand(block, choices: ["colour_mode": "same_colour"])

        XCTAssertEqual(Array(expansion.atomicActions.prefix(3)).map(\.type), [.fpsc, .ch, .sc])
        XCTAssertEqual(expansion.atomicActions.first(where: { $0.type == .sc })?.note, "counts as fake FPdc")
        XCTAssertEqual(expansion.atomicActions.last?.type, .ch)
        XCTAssertTrue(expansion.warnings.isEmpty)
    }

    func testCrochetIRCompilerEmitsCustomActionForAmbiguousSource() throws {
        let block = CrochetIRInstructionBlock(
            title: "Border",
            sourceText: "work evenly around",
            nodes: [
                .ambiguous(CrochetIRAmbiguous(
                    reason: "Cannot determine the stitch count from the source text.",
                    sourceText: "work evenly around"
                ))
            ]
        )

        let expansion = try CrochetIRCompiler().expand(block)

        XCTAssertEqual(expansion.atomicActions.count, 1)
        XCTAssertEqual(expansion.atomicActions[0].type, .custom)
        XCTAssertEqual(expansion.atomicActions[0].instruction, "work evenly around")
        XCTAssertEqual(expansion.warnings.map(\.code), ["ir_ambiguous_source"])
    }

    func testCrochetIRValidatorReportsInvalidTailOverrideAndDescriptorStitch() {
        let invalidTail = CrochetIRInstructionBlock(
            title: "Invalid Repeat",
            sourceText: "omit too much",
            nodes: [
                .repeatBlock(CrochetIRRepeat(
                    times: 1,
                    body: [.stitch(CrochetIRStitch(type: .sc, count: 1))],
                    lastIterationTransform: CrochetIRRepeatLastIterationTransform(removeTailNodeCount: 2)
                ))
            ]
        )
        let descriptor = CrochetIRInstructionBlock(
            title: "Descriptor",
            sourceText: "FLO",
            nodes: [.stitch(CrochetIRStitch(type: .flo, count: 1))]
        )

        let invalidTailReport = CrochetIRCompiler().validate(invalidTail)
        let descriptorReport = CrochetIRCompiler().validate(descriptor)

        XCTAssertTrue(invalidTailReport.hasErrors)
        XCTAssertTrue(invalidTailReport.issues.contains { $0.code == "ir_invalid_last_iteration_tail_removal" })
        XCTAssertTrue(descriptorReport.hasErrors)
        XCTAssertTrue(descriptorReport.issues.contains { $0.code == "ir_contains_non_action_type" })
    }

    func testAtomizeRoundsUsesCrochetIRCompilerPathWhenAvailable() async throws {
        let outline = makeSingleRoundOutlineResponse(
            rawInstruction: "[dc inc, 8hdc, dc inc, ch3] repeat 3 times, omit the final ch3. Instead, work ch1, then 1hdc into the top of the first ch3.",
            summary: "Repeat the squaring sequence and replace the final chain space.",
            targetStitchCount: 37
        )
        let repeatBody: [CrochetIRNode] = [
            .stitch(CrochetIRStitch(type: .dc, count: 2, note: "dc inc", notePlacement: .all)),
            .stitch(CrochetIRStitch(type: .hdc, count: 8)),
            .stitch(CrochetIRStitch(type: .dc, count: 2, note: "dc inc", notePlacement: .all)),
            .stitch(CrochetIRStitch(type: .ch, count: 3))
        ]
        let irResponse = CrochetIRAtomizationResponse(rounds: [
            CrochetIRInstructionBlock(
                title: "Round 1",
                sourceText: outline.parts[0].rounds[0].rawInstruction,
                expectedProducedStitches: 37,
                nodes: [
                    .repeatBlock(CrochetIRRepeat(
                        times: 3,
                        body: repeatBody,
                        lastIterationTransform: CrochetIRRepeatLastIterationTransform(
                            removeTailNodeCount: 1,
                            append: [
                                .stitch(CrochetIRStitch(type: .ch, count: 1)),
                                .stitch(CrochetIRStitch(type: .hdc, count: 1, note: "into the top of the first ch3", notePlacement: .all))
                            ]
                        )
                    ))
                ]
            )
        ])
        let parserClient = IRAtomizationClient(outlineResponse: outline, irResponse: irResponse)
        let importer = PatternImportService(
            parserClient: parserClient,
            extractor: HTMLExtractionService(),
            logger: ConsoleTraceLogger()
        )

        let record = try await importer.importTextPattern(from: "Wolf squaring")
        let target = try firstRoundReferences(in: record.project, count: 1)
        let updates = try await importer.atomizeRounds(in: record.project, targets: target)

        XCTAssertEqual(updates.first?.atomicActions.count, 44)
        XCTAssertEqual(updates.first?.resolvedTargetStitchCount, 37)
        XCTAssertEqual(updates.first?.atomicActions.last?.note, "into the top of the first ch3")
        let irCount = await parserClient.irCallCount()
        XCTAssertEqual(irCount, 1)
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


private actor IRAtomizationClient: PatternLLMParsing {
    private let outlineResponse: PatternOutlineResponse
    private let irResponse: CrochetIRAtomizationResponse
    private var irCalls = 0

    init(outlineResponse: PatternOutlineResponse, irResponse: CrochetIRAtomizationResponse) {
        self.outlineResponse = outlineResponse
        self.irResponse = irResponse
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
        irCalls += 1
        return CrochetIRAtomizationResponse(rounds: Array(irResponse.rounds.prefix(rounds.count)))
    }

    func parseImagePattern(
        imageData: Data,
        mimeType: String,
        fileName: String,
        context: ParseRequestContext
    ) async throws -> PatternParseResponse {
        SampleDataFactory.demoImageParseResponse
    }

    func irCallCount() -> Int { irCalls }
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

    func parseTextRoundsToIR(
        projectTitle: String,
        materials: [String],
        rounds: [AtomizationRoundInput],
        context: ParseRequestContext
    ) async throws -> CrochetIRAtomizationResponse {
        SampleDataFactory.demoIRAtomizationResponse
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
