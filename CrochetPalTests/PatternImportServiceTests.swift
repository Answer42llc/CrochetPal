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
        let allowedTypes = try XCTUnwrap(typeDefinition["enum"] as? [Any])
        let allowedTypeStrings = allowedTypes.compactMap { $0 as? String }
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
        XCTAssertTrue(allowedTypes.contains { $0 is NSNull })
        XCTAssertFalse(allowedTypeStrings.contains("blo"))
        XCTAssertFalse(allowedTypeStrings.contains("flo"))
        XCTAssertFalse(allowedTypeStrings.contains("custom"))

        let controlKindDefinition = try XCTUnwrap(segmentProperties["controlKind"] as? [String: Any])
        let controlKindValues = try XCTUnwrap(controlKindDefinition["enum"] as? [Any])
        XCTAssertEqual(controlKindValues.compactMap { $0 as? String }, ControlSegmentKind.allCases.map(\.rawValue))
        XCTAssertTrue(controlKindValues.contains { $0 is NSNull })

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
        XCTAssertTrue(systemPrompt?.contains("turn or skip (skipping one or more stitches)") == true)
        XCTAssertTrue(systemPrompt?.contains("skip is not a stitch, it is a control step") == true)
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
        XCTAssertEqual(update.resolvedTargetStitchCount, 0)
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
        XCTAssertEqual(updates.first?.resolvedTargetStitchCount, 113)
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

        XCTAssertEqual(update?.resolvedTargetStitchCount, 12)
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
        XCTAssertEqual(updates.first?.resolvedTargetStitchCount, 7)
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
