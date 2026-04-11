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
        XCTAssertEqual(updates[0].atomicActions.first?.instruction, "mr")
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

    func testAtomizationLLMRequestUsesCompactActionGroupSchema() async throws {
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
        let actionGroups = try XCTUnwrap(roundProperties["actionGroups"] as? [String: Any])
        let actionGroupItem = try XCTUnwrap(actionGroups["items"] as? [String: Any])
        let actionGroupProperties = try XCTUnwrap(actionGroupItem["properties"] as? [String: Any])
        XCTAssertNil(actionGroupProperties["sequenceIndex"])
        XCTAssertNotNil(actionGroupProperties["count"])
        XCTAssertNotNil(actionGroupProperties["note"])

        let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
        let systemPrompt = messages.first?["content"] as? String
        let userPrompt = messages.last?["content"] as? String
        XCTAssertTrue(systemPrompt?.contains("compact action groups") == true)
        XCTAssertTrue(systemPrompt?.contains("\"sc inc\" must become one sc action followed by one inc action.") == true)
        XCTAssertTrue(systemPrompt?.contains("Prefer attaching contextual modifiers to note") == true)
        XCTAssertTrue(systemPrompt?.contains("Map \"magic loop\" and \"magic ring\" to type \"mr\".") == true)
        XCTAssertTrue(systemPrompt?.contains("Map \"slst\", \"sl st\", and \"slip stitch\" to type \"sl_st\".") == true)
        XCTAssertTrue(systemPrompt?.contains("Raw instruction: \"With grey yarn: Magic loop, ch1, 7sc, slst to the first sc.\"") == true)
        XCTAssertTrue(systemPrompt?.contains("Incorrect output groups: custom(\"magic loop\")") == true)
        XCTAssertTrue(userPrompt?.contains("Only use each round's rawInstruction as the stitch source of truth.") == true)
        XCTAssertFalse(userPrompt?.contains("Previous attempt failed validation.") == true)
        XCTAssertFalse(userPrompt?.contains("\"summary\"") == true)
        XCTAssertFalse(userPrompt?.contains("\"notes\"") == true)
    }

    func testDeepSeekTextLLMRequestIncludesProviderRoutingPayload() async throws {
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
        let provider = try XCTUnwrap(object["provider"] as? [String: Any])
        XCTAssertEqual(provider["require_parameters"] as? Bool, true)
        XCTAssertEqual(provider["allow_fallbacks"] as? Bool, false)
        XCTAssertEqual(provider["order"] as? [String], ["atlas-cloud/fp8", "siliconflow/fp8"])
    }

    func testAtomizeRoundsPreservesModelReturnedControlActionsAndNotes() async throws {
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
                            ParsedActionGroup(type: .custom, count: 1, instruction: "change back to grey yarn on final yo", producedStitches: 0, note: nil),
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
        let updates = try await importer.atomizeRounds(in: record.project, targets: target)
        let actions = try XCTUnwrap(updates.first?.atomicActions)

        XCTAssertEqual(actions.map(\.type), [.sc, .custom, .inc, .custom, .slSt])
        XCTAssertEqual(actions[1].instruction, "change to white yarn")
        XCTAssertEqual(actions[2].note, "work this increase in the same st as the previous sc")
        XCTAssertEqual(actions[3].instruction, "change back to grey yarn on final yo")
    }

    func testAtomizeRoundsPreservesSameStitchNoteOnOriginalAction() async throws {
        let html = try fixture(named: "mouse-pattern", extension: "html")
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(html.utf8))
        }

        // Simulate LLM incorrectly placing "same stitch" note on the sc action
        let importer = PatternImportService(
            parserClient: FixturePatternParsingClient(
                outlineResponse: SampleDataFactory.demoOutlineResponse,
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

        let record = try await importer.importWebPattern(from: "https://example.com/pattern")
        let target = try firstRoundReferences(in: record.project, count: 1)
        let updates = try await importer.atomizeRounds(in: record.project, targets: target)
        let actions = try XCTUnwrap(updates.first?.atomicActions)

        XCTAssertEqual(actions.map(\.type), [.ch, .sc, .inc])
        XCTAssertNil(actions[0].note)
        XCTAssertEqual(actions[1].note, "inc in the same stitch")
        XCTAssertNil(actions[2].note)
    }

    func testAtomizeRoundsDefaultsCustomControlActionsToZeroProducedStitches() async throws {
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
                            ParsedActionGroup(type: .custom, count: 1, instruction: "change to white yarn", producedStitches: nil)
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
        let updates = try await importer.atomizeRounds(in: record.project, targets: target)

        XCTAssertEqual(updates.first?.atomicActions.first?.type, .custom)
        XCTAssertEqual(updates.first?.atomicActions.first?.instruction, "change to white yarn")
        XCTAssertEqual(updates.first?.atomicActions.first?.producedStitches, 0)
    }

    func testRoundAtomizationDecodeRejectsUnsupportedActionType() throws {
        let data = Data("""
        {
          "rounds": [
            {
              "actionGroups": [
                { "type": "magic loop", "count": 1, "instruction": null, "producedStitches": null, "note": null }
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
        let updates = try await importer.atomizeRounds(in: record.project, targets: targets)

        let callCount = await parserClient.atomizationCallCount()
        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(updates.first?.atomicActions.map(\.type), [.custom, .ch, .sc, .sc, .sc, .sc, .sc, .sc, .sc, .slSt])
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
                {"rounds":[{"actionGroups":[{"type":"mr","count":1,"instruction":"mr","producedStitches":0}]}]
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

    private func firstRoundReferences(in project: CrochetProject, count: Int) throws -> [RoundReference] {
        let references = project.parts.flatMap { part in
            part.rounds.map { RoundReference(partID: part.id, roundID: $0.id) }
        }
        return Array(references.prefix(count))
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
