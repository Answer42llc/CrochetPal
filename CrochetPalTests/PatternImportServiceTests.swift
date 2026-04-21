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
        XCTAssertTrue(CrochetStitchCatalog.isValidStitchTag("sc"))
        XCTAssertTrue(CrochetStitchCatalog.isValidStitchTag("fpdc"))
        XCTAssertTrue(CrochetTermDictionary.supportedStitchTagSet.contains("fpdc"))
        XCTAssertFalse(CrochetStitchCatalog.isValidStitchTag("flo"))
        XCTAssertFalse(CrochetStitchCatalog.isValidStitchTag("blo"))
        XCTAssertFalse(CrochetStitchCatalog.isValidStitchTag("custom"))
    }

    func testImportImagePatternRejectsNonActionAtomicType() async throws {
        var imageResponse = SampleDataFactory.demoImageParseResponse
        imageResponse.parts[0].rounds[0].atomicActions[0].stitchTag = "flo"

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
            abbreviations: [],
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
            abbreviations: [],
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
            abbreviations: [],
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
            abbreviations: [],
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
            abbreviations: [],
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
            abbreviations: [],
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
            abbreviations: [],
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
            abbreviations: [],
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
            abbreviations: [],
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

    /// Helper: wrap a list of statement kinds into a Block.
    private func makeBlock(_ kinds: [CrochetIRStatementKind]) -> CrochetIRBlock {
        CrochetIRBlock(statements: kinds.map { CrochetIRStatement(kind: $0) })
    }

    private func stitchOperation(_ tag: String, count: Int = 1, note: String? = nil, notePlacement: AtomizedNotePlacement = .first) -> CrochetIRStatementKind {
        .operation(CrochetIROperation(
            semantics: .stitchProducing,
            actionTag: tag,
            stitch: tag,
            count: count,
            note: note,
            notePlacement: notePlacement
        ))
    }

    private func increaseOperation(base stitch: String, producedStitches: Int = 2, note: String? = "inc") -> CrochetIRStatementKind {
        .operation(CrochetIROperation(
            semantics: .increase,
            actionTag: "increase",
            stitch: stitch,
            count: 1,
            note: note,
            notePlacement: .all,
            producedStitches: producedStitches
        ))
    }

    func testCompilerExpandsHomogeneousRepeatOnly() throws {
        // Post-normalization IR for "[dc inc, 8hdc, dc inc, ch3] repeat 3 times, omit the final ch3.
        //  Instead, work ch1, then 1hdc into the top of the first ch3."
        // → repeatBlock(times: 2) + flat final iteration with ch1 + hdc replacing the final ch3.
        let unchangedIteration = makeBlock([
            increaseOperation(base: "dc", note: "dc inc"),
            stitchOperation("hdc", count: 8),
            increaseOperation(base: "dc", note: "dc inc"),
            stitchOperation("ch", count: 3)
        ])
        let block = CrochetIRInstructionBlock(
            title: "Squaring",
            sourceText: "Wolf squaring normalized form.",
            expectedProducedStitches: 37,
            body: CrochetIRBlock(statements: [
                CrochetIRStatement(kind: .repeatBlock(CrochetIRRepeatBlock(
                    times: 2,
                    body: unchangedIteration,
                    sourceRepeatCount: 3,
                    normalizationNote: "Final iteration normalized out below."
                ))),
                CrochetIRStatement(kind: increaseOperation(base: "dc", note: "dc inc")),
                CrochetIRStatement(kind: stitchOperation("hdc", count: 8)),
                CrochetIRStatement(kind: increaseOperation(base: "dc", note: "dc inc")),
                CrochetIRStatement(kind: stitchOperation("ch", count: 1)),
                CrochetIRStatement(kind: .operation(CrochetIROperation(
                    semantics: .stitchProducing,
                    actionTag: "hdc",
                    stitch: "hdc",
                    count: 1,
                    target: "top of the first ch3"
                )))
            ])
        )

        let expansion = try CrochetIRCompiler().expand(block)

        // 3 total iterations of the original repeat (2 via repeatBlock + 1 flat):
        //   dc inc (2 dc) + 8 hdc + dc inc (2 dc) + ch3 = 15 actions × 2 = 30
        //   + dc inc (2) + 8 hdc + dc inc (2) + ch × 1 + hdc × 1 = 14
        //   Total = 44.
        XCTAssertEqual(expansion.atomicActions.count, 44)
        XCTAssertEqual(expansion.producedStitchCount, 37)
        XCTAssertEqual(expansion.atomicActions.last?.stitchTag, "hdc")
        XCTAssertEqual(expansion.atomicActions.last?.note, "top of the first ch3")
        // The last chain before the final hdc should be ch (count=1 → 1 action), not ch3.
        let lastChIndex = expansion.atomicActions.lastIndex(where: { $0.stitchTag == "ch" })
        XCTAssertNotNil(lastChIndex)
        if let lastChIndex {
            // The final 2 actions are "ch × 1, hdc × 1 (top of first ch3)".
            XCTAssertEqual(lastChIndex, expansion.atomicActions.count - 2)
            // The 5-action final iteration contributes exactly 1 ch (count=1), not 3.
            let tail = expansion.atomicActions.suffix(5)
            XCTAssertEqual(tail.filter { $0.stitchTag == "ch" }.count, 1)
        }
        XCTAssertTrue(expansion.warnings.isEmpty)
    }

    func testCompilerTraversesNestedRepeatInsideRepeat() throws {
        // [[A, B] × 2, C] × 2 → output should be A B A B C A B A B C.
        let innerRepeat = CrochetIRStatement(kind: .repeatBlock(CrochetIRRepeatBlock(
            times: 2,
            body: makeBlock([
                stitchOperation("sc"),
                stitchOperation("dc")
            ])
        )))
        let outerBody = CrochetIRBlock(statements: [
            innerRepeat,
            CrochetIRStatement(kind: stitchOperation("hdc"))
        ])
        let block = CrochetIRInstructionBlock(
            title: "Nested",
            sourceText: "[[sc, dc] × 2, hdc] × 2",
            body: CrochetIRBlock(statements: [
                CrochetIRStatement(kind: .repeatBlock(CrochetIRRepeatBlock(times: 2, body: outerBody)))
            ])
        )

        let expansion = try CrochetIRCompiler().expand(block)
        XCTAssertEqual(expansion.atomicActions.map(\.stitchTag), [
            "sc", "dc", "sc", "dc", "hdc",
            "sc", "dc", "sc", "dc", "hdc"
        ])
    }

    func testValidatorRejectsUnnormalizedIterationException() {
        // repeatBlock that still carries "omit the final ch3" in its sourceText with no
        // normalizationNote, and no flat tail → validator must flag it.
        let block = CrochetIRInstructionBlock(
            title: "Not normalized",
            sourceText: "[dc inc, 8hdc, dc inc, ch3] repeat 3 times, omit the final ch3. Instead, work ch1, hdc.",
            body: CrochetIRBlock(statements: [
                CrochetIRStatement(
                    kind: .repeatBlock(CrochetIRRepeatBlock(
                        times: 3,
                        body: makeBlock([
                            increaseOperation(base: "dc", note: "dc inc"),
                            stitchOperation("hdc", count: 8),
                            increaseOperation(base: "dc", note: "dc inc"),
                            stitchOperation("ch", count: 3)
                        ])
                    )),
                    sourceText: "[dc inc, 8hdc, dc inc, ch3] repeat 3 times, omit the final ch3. Instead, ch1, hdc."
                )
            ])
        )

        let report = CrochetIRCompiler().validate(block)
        XCTAssertTrue(report.hasErrors)
        XCTAssertTrue(report.issues.contains { $0.code == "ir_iteration_specific_exception_not_normalized" })
    }

    func testValidatorRejectsDescriptorStitch() {
        let descriptor = CrochetIRInstructionBlock(
            title: "Descriptor",
            sourceText: "FLO",
            body: makeBlock([stitchOperation("flo")])
        )
        let report = CrochetIRCompiler().validate(descriptor)
        XCTAssertTrue(report.hasErrors)
        XCTAssertTrue(report.issues.contains { $0.code == "ir_contains_non_action_type" })
    }

    func testConditionalChoiceIDIsSharedAcrossStatements() {
        // Two conditionals sharing the same choiceID and identical branch value set → valid.
        let sharedBranches: [CrochetIRConditionalBranch] = [
            CrochetIRConditionalBranch(value: "diff", label: "Different colour", body: makeBlock([stitchOperation("fpdc")])),
            CrochetIRConditionalBranch(value: "same", label: "Same colour", body: makeBlock([stitchOperation("sc")]))
        ]
        let validBlock = CrochetIRInstructionBlock(
            title: "Round 5 shared choice",
            sourceText: "...",
            body: CrochetIRBlock(statements: [
                CrochetIRStatement(kind: .conditional(CrochetIRConditional(
                    choiceID: "round5_start",
                    question: "Using a different colour?",
                    branches: sharedBranches,
                    defaultBranchValue: "same"
                ))),
                CrochetIRStatement(kind: stitchOperation("slst")),
                CrochetIRStatement(kind: .conditional(CrochetIRConditional(
                    choiceID: "round5_start",
                    question: "Using a different colour?",
                    branches: sharedBranches,
                    defaultBranchValue: "same"
                )))
            ])
        )
        let validReport = CrochetIRCompiler().validate(validBlock)
        XCTAssertFalse(validReport.issues.contains { $0.code == "ir_conditional_choice_id_mismatch" })

        // Mismatched branch value sets across the same choiceID → should be flagged.
        let mismatchBranches: [CrochetIRConditionalBranch] = [
            CrochetIRConditionalBranch(value: "diff", label: "Different", body: makeBlock([stitchOperation("fpdc")])),
            CrochetIRConditionalBranch(value: "other", label: "Other", body: makeBlock([stitchOperation("sc")]))
        ]
        let invalidBlock = CrochetIRInstructionBlock(
            title: "Round 5 mismatched choice",
            sourceText: "...",
            body: CrochetIRBlock(statements: [
                CrochetIRStatement(kind: .conditional(CrochetIRConditional(
                    choiceID: "round5_start",
                    question: "Q1",
                    branches: sharedBranches,
                    defaultBranchValue: "same"
                ))),
                CrochetIRStatement(kind: .conditional(CrochetIRConditional(
                    choiceID: "round5_start",
                    question: "Q2",
                    branches: mismatchBranches,
                    defaultBranchValue: "other"
                )))
            ])
        )
        let invalidReport = CrochetIRCompiler().validate(invalidBlock)
        XCTAssertTrue(invalidReport.issues.contains { $0.code == "ir_conditional_choice_id_mismatch" })
    }

    func testUnknownActionTagStillCompiles() throws {
        // A bookkeeping action the compiler has never seen — it should still produce one
        // AtomicAction with type=.custom and a sensible human-readable instruction.
        let block = CrochetIRInstructionBlock(
            title: "Unknown action",
            sourceText: "Attach a bead.",
            body: makeBlock([
                .operation(CrochetIROperation(
                    semantics: .bookkeeping,
                    actionTag: "beadPlacement",
                    instruction: "Attach a bead to the current stitch."
                ))
            ])
        )
        let expansion = try CrochetIRCompiler().expand(block)
        XCTAssertEqual(expansion.atomicActions.count, 1)
        XCTAssertEqual(expansion.atomicActions.first?.semantics, .bookkeeping)
        XCTAssertEqual(expansion.atomicActions.first?.actionTag, "beadPlacement")
        XCTAssertEqual(expansion.atomicActions.first?.instruction, "Attach a bead to the current stitch.")
    }

    func testStitchProducingRequiresStitchField() {
        let block = CrochetIRInstructionBlock(
            title: "Missing stitch",
            sourceText: "...",
            body: makeBlock([
                .operation(CrochetIROperation(
                    semantics: .stitchProducing,
                    actionTag: "dc",
                    stitch: nil,
                    count: 1
                ))
            ])
        )
        let report = CrochetIRCompiler().validate(block)
        XCTAssertTrue(report.hasErrors)
        XCTAssertTrue(report.issues.contains { $0.code == "ir_operation_semantics_mismatch" })
    }

    func testCompilerExpandsRepeatTimes5WithFlattenedFinalIteration() throws {
        // Round 5: "(ch 3, FPsc, ch 3, FPdc) × 6, omitting the last FPdc on the last repeat."
        // Normalized: repeatBlock(times: 5) + flat (ch3, FPsc, ch3).
        let iterationBody = makeBlock([
            stitchOperation("ch", count: 3),
            stitchOperation("fpsc", note: "around next Popcorn", notePlacement: .all),
            stitchOperation("ch", count: 3),
            stitchOperation("fpdc", note: "around next FPhdc", notePlacement: .all)
        ])
        let block = CrochetIRInstructionBlock(
            title: "Round 5",
            sourceText: "Round 5 normalized.",
            body: CrochetIRBlock(statements: [
                CrochetIRStatement(kind: .repeatBlock(CrochetIRRepeatBlock(
                    times: 5,
                    body: iterationBody,
                    sourceRepeatCount: 6,
                    normalizationNote: "Last FPdc omitted on the final repeat; normalized as repeat 5 + flat final."
                ))),
                CrochetIRStatement(kind: stitchOperation("ch", count: 3)),
                CrochetIRStatement(kind: stitchOperation("fpsc", note: "around next Popcorn", notePlacement: .all)),
                CrochetIRStatement(kind: stitchOperation("ch", count: 3))
            ])
        )
        let expansion = try CrochetIRCompiler().expand(block)
        let fpdcCount = expansion.atomicActions.filter { $0.stitchTag == "fpdc" }.count
        let fpscCount = expansion.atomicActions.filter { $0.stitchTag == "fpsc" }.count
        // 5 iterations produce 5 FPdc; the flat tail has no FPdc. Total = 5 (not 6).
        XCTAssertEqual(fpdcCount, 5)
        XCTAssertEqual(fpscCount, 6)
        XCTAssertEqual(expansion.atomicActions.last?.stitchTag, "ch")
    }

    func testAtomizeRoundsUsesCrochetIRCompilerPathWhenAvailable() async throws {
        let outline = makeSingleRoundOutlineResponse(
            rawInstruction: "[dc inc, 8hdc, dc inc, ch3] repeat 3 times, omit the final ch3. Instead, work ch1, then 1hdc into the top of the first ch3.",
            summary: "Repeat the squaring sequence and replace the final chain space.",
            targetStitchCount: 37
        )
        let unchangedIteration = CrochetIRBlock(statements: [
            CrochetIRStatement(kind: .operation(CrochetIROperation(
                semantics: .increase,
                actionTag: "increase",
                stitch: "dc",
                count: 1,
                note: "dc inc",
                notePlacement: .all,
                producedStitches: 2
            ))),
            CrochetIRStatement(kind: .operation(CrochetIROperation(
                semantics: .stitchProducing,
                actionTag: "hdc",
                stitch: "hdc",
                count: 8
            ))),
            CrochetIRStatement(kind: .operation(CrochetIROperation(
                semantics: .increase,
                actionTag: "increase",
                stitch: "dc",
                count: 1,
                note: "dc inc",
                notePlacement: .all,
                producedStitches: 2
            ))),
            CrochetIRStatement(kind: .operation(CrochetIROperation(
                semantics: .stitchProducing,
                actionTag: "ch",
                stitch: "ch",
                count: 3
            )))
        ])
        let irResponse = CrochetIRAtomizationResponse(rounds: [
            CrochetIRInstructionBlock(
                title: "Round 1",
                sourceText: outline.parts[0].rounds[0].rawInstruction,
                expectedProducedStitches: 37,
                body: CrochetIRBlock(statements: [
                    CrochetIRStatement(kind: .repeatBlock(CrochetIRRepeatBlock(
                        times: 2,
                        body: unchangedIteration,
                        sourceRepeatCount: 3,
                        normalizationNote: "Final iteration normalized to flat statements below."
                    ))),
                    CrochetIRStatement(kind: .operation(CrochetIROperation(
                        semantics: .increase,
                        actionTag: "increase",
                        stitch: "dc",
                        count: 1,
                        note: "dc inc",
                        notePlacement: .all,
                        producedStitches: 2
                    ))),
                    CrochetIRStatement(kind: .operation(CrochetIROperation(
                        semantics: .stitchProducing,
                        actionTag: "hdc",
                        stitch: "hdc",
                        count: 8
                    ))),
                    CrochetIRStatement(kind: .operation(CrochetIROperation(
                        semantics: .increase,
                        actionTag: "increase",
                        stitch: "dc",
                        count: 1,
                        note: "dc inc",
                        notePlacement: .all,
                        producedStitches: 2
                    ))),
                    CrochetIRStatement(kind: .operation(CrochetIROperation(
                        semantics: .stitchProducing,
                        actionTag: "ch",
                        stitch: "ch",
                        count: 1
                    ))),
                    CrochetIRStatement(kind: .operation(CrochetIROperation(
                        semantics: .stitchProducing,
                        actionTag: "hdc",
                        stitch: "hdc",
                        count: 1,
                        target: "top of the first ch3"
                    )))
                ])
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
        XCTAssertEqual(updates.first?.producedStitchCount, 37)
        XCTAssertEqual(updates.first?.atomicActions.last?.stitchTag, "hdc")
        XCTAssertEqual(updates.first?.atomicActions.last?.note, "top of the first ch3")
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
            abbreviations: [],
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
            abbreviations: [],
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

// MARK: - IR fixture: real LLM end-to-end test

/// Integration tests that exercise the new Block/Statement/Operation IR against a captured
/// LLM response. The fixture was produced once by running
/// `CP_CAPTURE_IR_FIXTURE=1 xcodebuild ... test` with a real API key; after that the
/// JSON is checked in and the structural test runs offline on every CI build.
final class IRAtomizationLLMIntegrationTests: XCTestCase {
    private let rawHTMLPath = "Fixtures/LLM/MouseCatToy/raw.html"
    private let irFixturePath = "Fixtures/LLM/MouseCatToy/ir_atomization.json"
    private let outlineFixturePath = "Fixtures/LLM/MouseCatToy/outline.json"
    private let sourceURL = URL(string: "https://sparkitectcrafts.com/mouse-cat-toy-crochet-pattern/")!

    /// Decodes the captured IR JSON with the current schema and reports which rounds pass
    /// validation. Rounds that fail validation are expected to trigger LLM repair in
    /// production, so we *don't* require 100% pass — but we do require:
    /// - every round decodes cleanly (proves Swift Codable matches the LLM schema)
    /// - at least one round compiles end-to-end to AtomicActions (proves the pipeline works
    ///   on real LLM output at all)
    /// - every round that validates also expands without throwing
    /// - validation failures come from the whitelisted set of "LLM quality" codes rather
    ///   than our new structural invariants (no iteration-exception smell, no choiceID
    ///   mismatch, no Codable-level data corruption)
    func testMouseCatToyIRFixtureIsCanonicalAndCompiles() throws {
        let data = try XCTUnwrap(Self.fixtureData(at: irFixturePath))
        let response = try JSONDecoder().decode(CrochetIRAtomizationResponse.self, from: data)
        XCTAssertFalse(response.rounds.isEmpty, "captured fixture must contain at least one round")

        let compiler = CrochetIRCompiler()

        // Structural invariants the refactor was specifically about. If the LLM ever
        // regresses and re-introduces iteration-specific exceptions or inconsistent
        // shared choiceIDs, this test will catch it.
        let structuralInvariantCodes: Set<String> = [
            "ir_iteration_specific_exception_not_normalized",
            "ir_conditional_choice_id_mismatch"
        ]

        var validRoundsCompiled = 0
        var llmQualityFailures: [(round: String, codes: [String])] = []

        for block in response.rounds {
            let report = compiler.validate(block)
            let errors = report.issues.filter { $0.severity == .error }

            // Structural invariants must never fail — that's our refactor's job.
            let structuralErrors = errors.filter { structuralInvariantCodes.contains($0.code) }
            XCTAssertTrue(
                structuralErrors.isEmpty,
                "Round '\(block.title)' violates a structural invariant: \(structuralErrors.map(\.code).joined(separator: ", "))"
            )

            if errors.isEmpty {
                let expansion = try compiler.expand(block)
                XCTAssertFalse(
                    expansion.atomicActions.isEmpty,
                    "Round '\(block.title)' validated but expanded to zero actions"
                )
                validRoundsCompiled += 1
            } else {
                llmQualityFailures.append((block.title, errors.map(\.code)))
            }
        }

        // If the LLM were totally broken no round would validate. We require at least one.
        XCTAssertGreaterThan(
            validRoundsCompiled,
            0,
            "No round passed validation — LLM output is structurally unusable. Failures: \(llmQualityFailures)"
        )

        // Log — helps when iterating on the prompt.
        if !llmQualityFailures.isEmpty {
            print("[IR fixture] LLM quality issues in \(llmQualityFailures.count) round(s): \(llmQualityFailures)")
        }
        print("[IR fixture] \(validRoundsCompiled)/\(response.rounds.count) rounds validated and compiled")
    }

    /// Asserts the IR invariants that the refactor was about: no `lastIterationTransform`
    /// is present anywhere (since we removed it), every repeat body is non-empty, and
    /// every operation carries a non-empty actionTag + semantics-consistent stitch.
    func testMouseCatToyIRRespectsNewIRInvariants() throws {
        let data = try XCTUnwrap(Self.fixtureData(at: irFixturePath))

        // Raw JSON check: the word "lastIterationTransform" must not appear. Since that
        // field no longer exists in the schema, the LLM cannot emit it, and any residual
        // occurrence would indicate stale data.
        let raw = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(
            raw.contains("lastIterationTransform"),
            "The captured IR must not carry the removed lastIterationTransform field."
        )

        let response = try JSONDecoder().decode(CrochetIRAtomizationResponse.self, from: data)

        for round in response.rounds {
            assertBlockInvariants(round.body, context: round.title)
        }
    }

    private func assertBlockInvariants(_ block: CrochetIRBlock, context: String) {
        for statement in block.statements {
            switch statement.kind {
            case let .operation(op):
                XCTAssertFalse(
                    op.actionTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    "[\(context)] operation is missing actionTag"
                )
                switch op.semantics {
                case .stitchProducing, .increase, .decrease:
                    XCTAssertNotNil(
                        op.stitch,
                        "[\(context)] operation with semantics \(op.semantics.rawValue) missing stitch"
                    )
                case .bookkeeping:
                    // bookkeeping MAY carry an optional stitch-ish tag (e.g. "mr", "fo").
                    // No assertion needed.
                    break
                }
            case let .repeatBlock(rb):
                XCTAssertGreaterThan(rb.times, 0, "[\(context)] repeatBlock times must be positive")
                XCTAssertFalse(
                    rb.body.statements.isEmpty,
                    "[\(context)] repeatBlock body must not be empty"
                )
                assertBlockInvariants(rb.body, context: "\(context) > repeat")
            case let .conditional(c):
                XCTAssertFalse(c.branches.isEmpty, "[\(context)] conditional must have at least one branch")
                for branch in c.branches {
                    assertBlockInvariants(branch.body, context: "\(context) > branch[\(branch.value)]")
                }
                if let common = c.commonBody {
                    assertBlockInvariants(common, context: "\(context) > commonBody")
                }
            case .note:
                break
            }
        }
    }

    /// CAPTURE STEP — only runs when the sentinel file `/tmp/crochet/CAPTURE_IR` exists.
    /// Reads credentials from `Config/Secrets.xcconfig` (same file the app itself uses).
    /// Runs the real LLM pipeline against the checked-in raw.html, then writes the
    /// outline + IR JSON back to the source tree.
    ///
    /// Notes:
    /// - This test drives the HTTP call itself rather than going through
    ///   `OpenAICompatibleLLMClient.sendChatCompletion`. The reason is that we want the
    ///   raw assistant content written to disk *before* decoding, so that if the LLM
    ///   emits something that doesn't match the new IR schema we can inspect the file.
    /// - The HTTP request body exactly mirrors the production code path (same system
    ///   prompt, same user prompt, same `response_format` schema).
    func testCaptureMouseCatToyIRFixtureFromRealLLM() async throws {
        let sentinelURL = URL(fileURLWithPath: "/tmp/crochet/CAPTURE_IR")
        guard FileManager.default.fileExists(atPath: sentinelURL.path) else {
            throw XCTSkip("Capture test disabled. `touch /tmp/crochet/CAPTURE_IR` to enable.")
        }

        let configuration = try Self.makeRuntimeConfigurationFromSecretsFile()
        let logger = ConsoleTraceLogger()
        let extractor = HTMLExtractionService()

        let html = try XCTUnwrap(Self.fixtureText(at: rawHTMLPath), "raw.html missing at \(rawHTMLPath)")
        let context = ParseRequestContext(
            traceID: "capture-\(UUID().uuidString)",
            parseRequestID: "capture-\(UUID().uuidString)",
            sourceType: .web
        )
        let extraction = extractor.extract(from: html, sourceURL: sourceURL, context: context, logger: logger)
        XCTAssertFalse(extraction.finalText.isEmpty, "HTML extractor returned empty text")
        try Self.writeText(extraction.finalText, to: "Fixtures/LLM/MouseCatToy/extracted_text.txt")

        // ----- Step 1: outline -----
        let outlineContent = try await Self.fetchAssistantContent(
            configuration: configuration,
            modelID: configuration.textModelID,
            systemPrompt: PromptFactory.textOutlineSystemPrompt(),
            userPrompt: PromptFactory.textOutlinePrompt(
                extractedText: extraction.finalText,
                titleHint: extraction.title
            ),
            responseFormat: PromptFactory.outlineResponseFormat()
        )
        try Self.writeText(outlineContent, to: "Fixtures/LLM/MouseCatToy/outline_raw.json")

        let outline: PatternOutlineResponse
        do {
            outline = try JSONDecoder().decode(
                PatternOutlineResponse.self,
                from: Data(outlineContent.utf8)
            )
            try Self.writePrettyJSON(outline, to: outlineFixturePath)
        } catch {
            XCTFail("Outline decode failed: \(error). Raw content saved to outline_raw.json.")
            return
        }

        // ----- Step 2: IR atomization -----
        let atomizationInputs: [AtomizationRoundInput] = outline.parts.flatMap { part in
            part.rounds.map { round in
                AtomizationRoundInput(
                    partName: part.name,
                    title: round.title,
                    rawInstruction: round.rawInstruction,
                    summary: round.summary,
                    targetStitchCount: round.targetStitchCount,
                    previousRoundStitchCount: nil,
                    abbreviations: outline.abbreviations
                )
            }
        }
        XCTAssertFalse(atomizationInputs.isEmpty, "Outline produced zero rounds")

        let irContent = try await Self.fetchAssistantContent(
            configuration: configuration,
            modelID: configuration.atomizationModelID,
            systemPrompt: PromptFactory.roundIRAtomizationSystemPrompt(),
            userPrompt: PromptFactory.roundIRAtomizationPrompt(
                projectTitle: outline.projectTitle,
                materials: outline.materials,
                rounds: atomizationInputs
            ),
            responseFormat: PromptFactory.irAtomizationResponseFormat()
        )
        try Self.writeText(irContent, to: "Fixtures/LLM/MouseCatToy/ir_raw.json")

        do {
            let ir = try JSONDecoder().decode(
                CrochetIRAtomizationResponse.self,
                from: Data(irContent.utf8)
            )
            try Self.writePrettyJSON(ir, to: irFixturePath)
            print("Captured \(ir.rounds.count) IR rounds → \(irFixturePath)")
        } catch {
            XCTFail("IR decode failed: \(error). Raw LLM content saved to ir_raw.json for inspection.")
        }
    }

    /// Performs a single chat-completion call against an OpenAI-compatible endpoint and
    /// returns the assistant's raw message content. Does NOT attempt to decode; callers
    /// save the content first and decode separately.
    private static func fetchAssistantContent(
        configuration: RuntimeConfiguration,
        modelID: String,
        systemPrompt: String,
        userPrompt: String,
        responseFormat: [String: Any]
    ) async throws -> String {
        var request = URLRequest(url: configuration.baseURL.appending(path: "chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "model": modelID,
            "temperature": 0,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt]
            ],
            "response_format": responseFormat
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let bodyPreview = String(data: data, encoding: .utf8).map { String($0.prefix(500)) } ?? ""
            throw NSError(
                domain: "CaptureIRFixture",
                code: status,
                userInfo: [NSLocalizedDescriptionKey: "HTTP \(status): \(bodyPreview)"]
            )
        }

        guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = envelope["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw NSError(
                domain: "CaptureIRFixture",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "could not extract assistant content"]
            )
        }
        return content
    }

    private static func writeText(_ text: String, to relativePath: String) throws {
        let url = fixtureURL(at: relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: Helpers

    /// Locates fixtures relative to the current test source file — avoids the need to
    /// register each JSON blob in the test target's bundle resources.
    private static func fixtureData(at relativePath: String) -> Data? {
        let url = fixtureURL(at: relativePath)
        return try? Data(contentsOf: url)
    }

    private static func fixtureText(at relativePath: String) -> String? {
        let url = fixtureURL(at: relativePath)
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private static func fixtureURL(at relativePath: String, file: StaticString = #filePath) -> URL {
        URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
    }

    private static func writePrettyJSON<T: Encodable>(_ value: T, to relativePath: String) throws {
        let url = fixtureURL(at: relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        try data.write(to: url)
    }

    /// Loads values from `Config/Secrets.xcconfig`, resolves `$(VAR)` references, and
    /// builds a RuntimeConfiguration. The xcconfig file syntax is `KEY = VALUE` with
    /// `$(OTHER_KEY)` expansion; we only need to handle that plus a `$(SLASH)` indirection
    /// for the URL (because xcconfig can't contain raw `//`).
    private static func makeRuntimeConfigurationFromSecretsFile() throws -> RuntimeConfiguration {
        let secretsURL = projectRootURL().appendingPathComponent("Config/Secrets.xcconfig")
        let contents = try String(contentsOf: secretsURL, encoding: .utf8)

        var raw: [String: String] = [:]
        for line in contents.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("//"), let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[..<eq].trimmingCharacters(in: .whitespaces)
            let value = trimmed[trimmed.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            raw[key] = value
        }

        func resolve(_ value: String) -> String {
            var result = value
            while let range = result.range(of: #"\$\([A-Z_]+\)"#, options: .regularExpression) {
                let key = String(result[range]).dropFirst(2).dropLast()
                result.replaceSubrange(range, with: raw[String(key)] ?? "")
            }
            return result
        }

        return try RuntimeConfiguration.load(values: [
            "OPENAI_API_KEY": resolve(raw["OPENAI_API_KEY"] ?? ""),
            "OPENAI_BASE_URL": resolve(raw["OPENAI_BASE_URL"] ?? ""),
            "TEXT_MODEL_ID": resolve(raw["TEXT_MODEL_ID"] ?? ""),
            "ATOMIZATION_MODEL_ID": resolve(raw["ATOMIZATION_MODEL_ID"] ?? raw["TEXT_MODEL_ID"] ?? ""),
            "VISION_MODEL_ID": resolve(raw["VISION_MODEL_ID"] ?? raw["TEXT_MODEL_ID"] ?? "")
        ])
    }

    /// Walks up from the current test file to the repo root (the parent of `CrochetPalTests/`).
    private static func projectRootURL(file: StaticString = #filePath) -> URL {
        URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent() // CrochetPalTests/
            .deletingLastPathComponent() // project root
    }
}
