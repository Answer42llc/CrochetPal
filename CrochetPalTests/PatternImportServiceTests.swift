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

    func testAtomizationMatchSubagentRequestUsesStrictJSONSchema() async throws {
        let capture = RequestCapture()
        let completionData = try completionResponseData(for: sampleAtomizationMatchEvaluation())
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

        _ = try await client.evaluateAtomizedRoundMatch(
            input: sampleAtomizationMatchEvaluationInput(),
            context: ParseRequestContext(traceID: "eval-trace", parseRequestID: "eval-parse", sourceType: .text)
        )

        let requestData = try XCTUnwrap(capture.body)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: requestData) as? [String: Any])
        XCTAssertEqual(object["model"] as? String, "text-model")

        let responseFormat = try XCTUnwrap(object["response_format"] as? [String: Any])
        let jsonSchema = try XCTUnwrap(responseFormat["json_schema"] as? [String: Any])
        XCTAssertEqual(jsonSchema["name"] as? String, "crochet_atomization_match_evaluation")
        let schema = try XCTUnwrap(jsonSchema["schema"] as? [String: Any])
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        XCTAssertNotNil(properties["verdict"])
        XCTAssertNotNil(properties["issueCodes"])
        XCTAssertNotNil(properties["missingElements"])
        XCTAssertNotNil(properties["extraElements"])

        let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
        XCTAssertTrue((messages.first?["content"] as? String)?.contains("independent crochet QA subagent") == true)
        XCTAssertTrue((messages.last?["content"] as? String)?.contains("\"rawInstruction\"") == true)
        XCTAssertTrue((messages.last?["content"] as? String)?.contains("\"atomicActions\"") == true)
    }

    func testAtomizationMatchSubagentRepairsMalformedJSONResponse() async throws {
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
                {"roundTitle":"Round 3","rawInstruction":"sc around. (9)","verdict":"normalized_match","confidence":0.96,"issueCodes":[],"missingElements":[],"extraElements":[],"rationale":"Semantically equivalent"
                """
                return (response, try self.completionResponseData(withContent: malformed))
            }

            return (response, try self.completionResponseData(for: sampleAtomizationMatchEvaluation()))
        }

        let session = URLSession(configuration: configuration())
        let client = OpenAICompatibleLLMClient(
            configuration: try testConfiguration(),
            session: session,
            logger: ConsoleTraceLogger()
        )

        let response = try await client.evaluateAtomizedRoundMatch(
            input: sampleAtomizationMatchEvaluationInput(),
            context: ParseRequestContext(traceID: "eval-repair-trace", parseRequestID: "eval-repair-parse", sourceType: .text)
        )

        XCTAssertEqual(capture.requestCount, 2)
        let requestObjects = try capture.bodies.map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: $0) as? [String: Any])
        }
        XCTAssertEqual(requestObjects.compactMap { $0["model"] as? String }, ["text-model", "text-model"])
        XCTAssertEqual(response.verdict, .normalizedMatch)
        XCTAssertEqual(response.roundTitle, "Round 3")
    }

    func testAtomizationMatchSubagentRepairsInconsistentVerdictEvidenceResponse() async throws {
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
                let inconsistent = """
                {
                  "roundTitle": "Round 3",
                  "rawInstruction": "sc around. (9)",
                  "verdict": "normalized_match",
                  "confidence": 0.9,
                  "issueCodes": ["extra_operation"],
                  "missingElements": [],
                  "extraElements": ["place marker"],
                  "rationale": "Semantically faithful but includes explicit bookkeeping."
                }
                """
                return (response, try self.completionResponseData(withContent: inconsistent))
            }

            return (response, try self.completionResponseData(for: sampleAtomizationMatchEvaluation()))
        }

        let session = URLSession(configuration: configuration())
        let client = OpenAICompatibleLLMClient(
            configuration: try testConfiguration(),
            session: session,
            logger: ConsoleTraceLogger()
        )

        let response = try await client.evaluateAtomizedRoundMatch(
            input: sampleAtomizationMatchEvaluationInput(),
            context: ParseRequestContext(traceID: "eval-consistency-trace", parseRequestID: "eval-consistency-parse", sourceType: .text)
        )

        XCTAssertEqual(capture.requestCount, 2)
        let requestObjects = try capture.bodies.map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: $0) as? [String: Any])
        }
        let secondMessages = try XCTUnwrap(requestObjects.last?["messages"] as? [[String: Any]])
        XCTAssertTrue((secondMessages.first?["content"] as? String)?.contains("repair an atomization match evaluation") == true)
        XCTAssertEqual(response.verdict, .normalizedMatch)
        XCTAssertTrue(response.issueCodes.isEmpty)
        XCTAssertTrue(response.extraElements.isEmpty)
    }

    func testAtomizationMatchSubagentCanonicalizesIrreparableConsistencyViolation() async throws {
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

            let inconsistent = """
            {
              "roundTitle": "Round 3",
              "rawInstruction": "sc around. (9)",
              "verdict": "normalized_match",
              "confidence": 0.9,
              "issueCodes": ["extra_operation"],
              "missingElements": [],
              "extraElements": ["place marker"],
              "rationale": "Semantically faithful but includes explicit bookkeeping."
            }
            """
            return (response, try self.completionResponseData(withContent: inconsistent))
        }

        let session = URLSession(configuration: configuration())
        let client = OpenAICompatibleLLMClient(
            configuration: try testConfiguration(),
            session: session,
            logger: ConsoleTraceLogger()
        )

        let response = try await client.evaluateAtomizedRoundMatch(
            input: sampleAtomizationMatchEvaluationInput(),
            context: ParseRequestContext(traceID: "eval-canonical-trace", parseRequestID: "eval-canonical-parse", sourceType: .text)
        )

        XCTAssertEqual(capture.requestCount, 2)
        XCTAssertEqual(response.verdict, .partialMatch)
        XCTAssertEqual(response.issueCodes, [.extraOperation])
        XCTAssertEqual(response.extraElements, ["place marker"])
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

    // MARK: - Range expansion tests

    func testRangeExpansionExpandsLargeRowRangeLocally() async throws {
        // Mandala Steering Wheel Cover style: a single "Rows 2-109: ..." instruction
        // must blow up into 108 individual rounds in the app, but the LLM-facing
        // outline payload carries just one range sentinel (avoiding output limit).
        let sentinelInstruction = "Ch 1, sc in first 3 sts. Hdc in next st. dc in next 8 sts. Hdc in next st. sc in last 3 sts."
        let outlineResponse = PatternOutlineResponse(
            projectTitle: "Mandala Steering Wheel Cover",
            materials: [],
            confidence: 0.9,
            abbreviations: [],
            parts: [
                OutlinedPatternPart(
                    name: "Cover",
                    rounds: [
                        OutlinedPatternRound(title: "Row 1", rawInstruction: "Ch 17.", summary: "Foundation chain.", targetStitchCount: nil),
                        OutlinedPatternRound(
                            title: "Rows 2-109",
                            rawInstruction: sentinelInstruction,
                            summary: "Repeat the same row 108 times.",
                            targetStitchCount: 16,
                            rangeStartNumber: 2,
                            rangeEndNumber: 109
                        ),
                        OutlinedPatternRound(title: "Weave in ends", rawInstruction: "Weave in ends.", summary: "Finish.", targetStitchCount: nil)
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

        XCTAssertEqual(rounds.count, 1 + 108 + 1)
        XCTAssertEqual(rounds[0].title, "Row 1")
        XCTAssertNil(rounds[0].macroRepeatGroupID)
        XCTAssertNil(rounds[0].macroRepeatSourceIndex)

        let expanded = Array(rounds[1...108])
        XCTAssertEqual(expanded.first?.title, "Row 2")
        XCTAssertEqual(expanded.last?.title, "Row 109")

        // All expanded rows share the same rawInstruction/summary/targetStitchCount.
        XCTAssertTrue(expanded.allSatisfy { $0.rawInstruction == sentinelInstruction })
        XCTAssertTrue(expanded.allSatisfy { $0.targetStitchCount == 16 })

        // All expanded rows must be pending (atomization hasn't run yet).
        XCTAssertTrue(expanded.allSatisfy { $0.atomizationStatus == .pending })

        // All expanded rows share one group ID and sourceIndex 0 — this is what lets
        // atomization propagate after a single LLM call covers all 108 rows.
        let groupIDs = Set(expanded.compactMap(\.macroRepeatGroupID))
        XCTAssertEqual(groupIDs.count, 1, "All range-expanded rows should share one groupID")
        XCTAssertTrue(expanded.allSatisfy { $0.macroRepeatSourceIndex == 0 })

        // Trailing non-stitch round passes through untouched.
        XCTAssertEqual(rounds.last?.title, "Weave in ends")
        XCTAssertNil(rounds.last?.macroRepeatGroupID)
    }

    func testRangeExpansionMouseCatToyMultipleIndependentRanges() async throws {
        // Mouse Cat Toy has three *independent* range expansions in the same part:
        //   Rounds 9-10: sc around. (18)
        //   Rounds 12-13: sc around. (21)
        //   Rounds 15-17: sc around. (24)
        // Each must get its own groupID so atomization results never leak across groups.
        let outlineResponse = PatternOutlineResponse(
            projectTitle: "Mouse Cat Toy",
            materials: [],
            confidence: 0.9,
            abbreviations: [],
            parts: [
                OutlinedPatternPart(
                    name: "Body",
                    rounds: [
                        OutlinedPatternRound(
                            title: "Rounds 9-10",
                            rawInstruction: "sc around. (18)",
                            summary: "Two plain rounds at 18 sts.",
                            targetStitchCount: 18,
                            rangeStartNumber: 9,
                            rangeEndNumber: 10
                        ),
                        OutlinedPatternRound(
                            title: "Rounds 12-13",
                            rawInstruction: "sc around. (21)",
                            summary: "Two plain rounds at 21 sts.",
                            targetStitchCount: 21,
                            rangeStartNumber: 12,
                            rangeEndNumber: 13
                        ),
                        OutlinedPatternRound(
                            title: "Rounds 15-17",
                            rawInstruction: "sc around. (24)",
                            summary: "Three plain rounds at 24 sts.",
                            targetStitchCount: 24,
                            rangeStartNumber: 15,
                            rangeEndNumber: 17
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

        XCTAssertEqual(rounds.count, 2 + 2 + 3)
        XCTAssertEqual(rounds.map(\.title), [
            "Round 9", "Round 10",
            "Round 12", "Round 13",
            "Round 15", "Round 16", "Round 17"
        ])

        // Every round uses the "Round" prefix (inferred from "Rounds …" sentinel title).
        XCTAssertTrue(rounds.allSatisfy { $0.title.hasPrefix("Round ") })

        // Group 1: Rounds 9-10 (targetStitchCount: 18)
        let group1 = Array(rounds[0...1])
        XCTAssertTrue(group1.allSatisfy { $0.targetStitchCount == 18 })
        XCTAssertTrue(group1.allSatisfy { $0.macroRepeatSourceIndex == 0 })
        let g1ID = try XCTUnwrap(group1.first?.macroRepeatGroupID)
        XCTAssertTrue(group1.allSatisfy { $0.macroRepeatGroupID == g1ID })

        // Group 2: Rounds 12-13 (targetStitchCount: 21)
        let group2 = Array(rounds[2...3])
        XCTAssertTrue(group2.allSatisfy { $0.targetStitchCount == 21 })
        XCTAssertTrue(group2.allSatisfy { $0.macroRepeatSourceIndex == 0 })
        let g2ID = try XCTUnwrap(group2.first?.macroRepeatGroupID)
        XCTAssertTrue(group2.allSatisfy { $0.macroRepeatGroupID == g2ID })

        // Group 3: Rounds 15-17 (targetStitchCount: 24)
        let group3 = Array(rounds[4...6])
        XCTAssertTrue(group3.allSatisfy { $0.targetStitchCount == 24 })
        XCTAssertTrue(group3.allSatisfy { $0.macroRepeatSourceIndex == 0 })
        let g3ID = try XCTUnwrap(group3.first?.macroRepeatGroupID)
        XCTAssertTrue(group3.allSatisfy { $0.macroRepeatGroupID == g3ID })

        // CRITICAL: three distinct groups must have three distinct groupIDs, even
        // though they all share sourceIndex 0. This is exactly what prevents
        // atomization propagation from conflating independent range expansions.
        XCTAssertEqual(Set([g1ID, g2ID, g3ID]).count, 3)
    }

    func testRangeExpansionCoexistsWithMacroRepeat() async throws {
        // A project with both a range sentinel and a macro-repeat sentinel — verify
        // each opens its own group and the two groupIDs differ.
        let outlineResponse = PatternOutlineResponse(
            projectTitle: "Mixed",
            materials: [],
            confidence: 0.9,
            abbreviations: [],
            parts: [
                OutlinedPatternPart(
                    name: "Body",
                    rounds: [
                        OutlinedPatternRound(title: "Round 1", rawInstruction: "MR, sc 6.", summary: "MR.", targetStitchCount: 6),
                        OutlinedPatternRound(title: "Round 2", rawInstruction: "Inc x 6.", summary: "Inc.", targetStitchCount: 12),
                        OutlinedPatternRound(title: "Round 3", rawInstruction: "sc around.", summary: "sc.", targetStitchCount: 12),
                        OutlinedPatternRound(
                            title: "Repeat Rounds 2-3",
                            rawInstruction: "Repeat Rounds 2-3 until 7 rounds.",
                            summary: "Repeat.",
                            targetStitchCount: nil,
                            repeatFromTitle: "Round 2",
                            repeatToTitle: "Round 3",
                            repeatUntilCount: 7,
                            repeatAfterRow: 3
                        ),
                        OutlinedPatternRound(
                            title: "Rounds 8-10",
                            rawInstruction: "sc around. (18)",
                            summary: "Three plain rounds.",
                            targetStitchCount: 18,
                            rangeStartNumber: 8,
                            rangeEndNumber: 10
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

        XCTAssertEqual(rounds.count, 3 + 4 + 3) // 3 base + 4 macro-repeat expanded + 3 range expanded

        // Macro-repeat group: rows 4..7 (indices 3..6)
        let macroGroup = Array(rounds[3...6])
        XCTAssertEqual(macroGroup.map(\.title), ["Round 4", "Round 5", "Round 6", "Round 7"])
        let macroGroupID = try XCTUnwrap(macroGroup.first?.macroRepeatGroupID)
        XCTAssertTrue(macroGroup.allSatisfy { $0.macroRepeatGroupID == macroGroupID })

        // Range group: rows 8..10 (indices 7..9)
        let rangeGroup = Array(rounds[7...9])
        XCTAssertEqual(rangeGroup.map(\.title), ["Round 8", "Round 9", "Round 10"])
        let rangeGroupID = try XCTUnwrap(rangeGroup.first?.macroRepeatGroupID)
        XCTAssertTrue(rangeGroup.allSatisfy { $0.macroRepeatGroupID == rangeGroupID })

        XCTAssertNotEqual(macroGroupID, rangeGroupID)
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

    func testIncreaseWithCountGreaterThanOneUsesPerIncreaseContract() throws {
        // Contract: producedStitches is per-single-increase. 8 hdc increases producing 16 stitches
        // total → count=8, producedStitches=2. Compiler should emit 16 atomic draft actions.
        let block = CrochetIRInstructionBlock(
            title: "Round with 8 hdc incs",
            sourceText: "work 1 hdcInc in each stitch, 16",
            expectedProducedStitches: 16,
            body: makeBlock([
                .operation(CrochetIROperation(
                    semantics: .increase,
                    actionTag: "increase",
                    stitch: "hdc",
                    count: 8,
                    notePlacement: .first,
                    producedStitches: 2
                ))
            ])
        )
        let expansion = try CrochetIRCompiler().expand(block)
        XCTAssertEqual(expansion.producedStitchCount, 16)
        XCTAssertEqual(expansion.atomicActions.count, 16)
        XCTAssertTrue(expansion.warnings.isEmpty)
    }

    func testIncreaseCompilerRepairsLegacyTotalEncoding() throws {
        // Safety net: LLM emits producedStitches as TOTAL (16 for count=8) instead of per-inc.
        // Compiler detects (rawProduced>count, rawProduced%count==0) and repairs to per-inc=2.
        let block = CrochetIRInstructionBlock(
            title: "Round with legacy total encoding",
            sourceText: "work 1 hdcInc in each stitch, 16",
            expectedProducedStitches: 16,
            body: makeBlock([
                .operation(CrochetIROperation(
                    semantics: .increase,
                    actionTag: "increase",
                    stitch: "hdc",
                    count: 8,
                    notePlacement: .first,
                    producedStitches: 16
                ))
            ])
        )
        let expansion = try CrochetIRCompiler().expand(block)
        XCTAssertEqual(expansion.producedStitchCount, 16)
        XCTAssertEqual(expansion.atomicActions.count, 16)
        XCTAssertFalse(expansion.warnings.contains { $0.code == "atomization_target_stitch_count_mismatch" })
    }

    func testValidatorWarnsWhenIncreaseProducedStitchesLooksLikeTotal() {
        let block = CrochetIRInstructionBlock(
            title: "Round with legacy total encoding",
            sourceText: "work 1 hdcInc in each stitch, 16",
            expectedProducedStitches: 16,
            body: makeBlock([
                .operation(CrochetIROperation(
                    semantics: .increase,
                    actionTag: "increase",
                    stitch: "hdc",
                    count: 8,
                    notePlacement: .first,
                    producedStitches: 16
                ))
            ])
        )
        let report = CrochetIRCompiler().validate(block)
        XCTAssertFalse(report.hasErrors)
        XCTAssertTrue(report.issues.contains { $0.code == "ir_increase_produced_stitches_looks_like_total" })
    }

    func testCompilerPropagatesSourceTextFromStatementToAtomicAction() throws {
        let stitchStatement = CrochetIRStatement(
            kind: .operation(CrochetIROperation(
                semantics: .stitchProducing,
                actionTag: "sc",
                stitch: "sc",
                count: 3
            )),
            sourceText: "3 sc in the next ch"
        )
        let increaseStatement = CrochetIRStatement(
            kind: .operation(CrochetIROperation(
                semantics: .increase,
                actionTag: "increase",
                stitch: "sc",
                count: 2,
                producedStitches: 2
            )),
            sourceText: "2 sc inc evenly"
        )
        let bookkeepingStatement = CrochetIRStatement(
            kind: .operation(CrochetIROperation(
                semantics: .bookkeeping,
                actionTag: "turn",
                count: 1,
                instruction: "turn"
            )),
            sourceText: "turn"
        )
        let noteStatement = CrochetIRStatement(
            kind: .note(CrochetIRNote(message: "You should have 10 stitches.", emitAsAction: true)),
            sourceText: "You should have 10 stitches."
        )
        let block = CrochetIRInstructionBlock(
            title: "Source text propagation",
            sourceText: "3 sc in the next ch, 2 sc inc evenly, turn. You should have 10 stitches.",
            body: CrochetIRBlock(statements: [
                stitchStatement,
                increaseStatement,
                bookkeepingStatement,
                noteStatement
            ])
        )

        let expansion = try CrochetIRCompiler().expand(block)

        // 3 sc + 2 sc inc (each inc → 2 producedStitches=1 actions) + 1 turn + 1 note = 3 + 4 + 1 + 1 = 9
        XCTAssertEqual(expansion.atomicActions.count, 9)

        // The first three stitch actions all share the stitch statement's sourceText.
        XCTAssertEqual(expansion.atomicActions[0].sourceText, "3 sc in the next ch")
        XCTAssertEqual(expansion.atomicActions[1].sourceText, "3 sc in the next ch")
        XCTAssertEqual(expansion.atomicActions[2].sourceText, "3 sc in the next ch")

        // Next four actions come from the increase statement (2 inc × 2 producedStitches each).
        XCTAssertEqual(expansion.atomicActions[3].sourceText, "2 sc inc evenly")
        XCTAssertEqual(expansion.atomicActions[6].sourceText, "2 sc inc evenly")

        // Bookkeeping and note each carry their own statement sourceText.
        XCTAssertEqual(expansion.atomicActions[7].sourceText, "turn")
        XCTAssertEqual(expansion.atomicActions[8].sourceText, "You should have 10 stitches.")
    }

    /// Inside a repeat whose body exposes a structural sourceText, every expanded action
    /// must inherit the body's sourceText — NOT the fine-grained leaf statement sourceText.
    /// This keeps the UI highlight anchored on a phrase that is unique in the raw
    /// instruction, avoiding first-occurrence collisions on ambiguous short strings
    /// (e.g. `"2dc"` appearing multiple times in `"(2dc, ch3, 2dc) in each corner..."`).
    func testCompilerUsesRepeatBodySourceTextForInnerActions() throws {
        let repeatStatement = CrochetIRStatement(
            kind: .repeatBlock(CrochetIRRepeatBlock(
                times: 4,
                body: CrochetIRBlock(
                    statements: [
                        CrochetIRStatement(
                            kind: .operation(CrochetIROperation(
                                semantics: .stitchProducing,
                                actionTag: "sc",
                                stitch: "sc",
                                count: 1
                            )),
                            sourceText: "sc"
                        ),
                        CrochetIRStatement(
                            kind: .operation(CrochetIROperation(
                                semantics: .stitchProducing,
                                actionTag: "ch",
                                stitch: "ch",
                                count: 1
                            )),
                            sourceText: "ch1"
                        )
                    ],
                    sourceText: "(sc, ch1) in each corner"
                )
            )),
            sourceText: "[(sc, ch1) in each corner] × 4"
        )
        let block = CrochetIRInstructionBlock(
            title: "Repeat body sourceText override",
            sourceText: "[(sc, ch1) in each corner] × 4",
            body: CrochetIRBlock(statements: [repeatStatement])
        )

        let expansion = try CrochetIRCompiler().expand(block)

        XCTAssertEqual(expansion.atomicActions.count, 8)
        XCTAssertTrue(
            expansion.atomicActions.allSatisfy { $0.sourceText == "(sc, ch1) in each corner" },
            "All actions inside the repeat should inherit the body sourceText, not the per-statement `sc`/`ch1` strings."
        )
    }

    /// When the repeat body does not carry its own sourceText, we do NOT force-override —
    /// the leaf statement's sourceText wins. This preserves today's behavior for IR that
    /// only annotates at the statement level.
    func testCompilerFallsBackToStatementSourceTextWhenRepeatBodyHasNone() throws {
        let repeatStatement = CrochetIRStatement(
            kind: .repeatBlock(CrochetIRRepeatBlock(
                times: 3,
                body: CrochetIRBlock(
                    statements: [
                        CrochetIRStatement(
                            kind: .operation(CrochetIROperation(
                                semantics: .stitchProducing,
                                actionTag: "sc",
                                stitch: "sc",
                                count: 2
                            )),
                            sourceText: "2 sc"
                        )
                    ]
                    // body.sourceText intentionally nil
                )
            )),
            sourceText: "[2 sc] × 3"
        )
        let block = CrochetIRInstructionBlock(
            title: "Repeat body without sourceText",
            sourceText: "[2 sc] × 3",
            body: CrochetIRBlock(statements: [repeatStatement])
        )

        let expansion = try CrochetIRCompiler().expand(block)

        XCTAssertEqual(expansion.atomicActions.count, 6)
        XCTAssertTrue(expansion.atomicActions.allSatisfy { $0.sourceText == "2 sc" })
    }

    // MARK: - HighlightRangeResolver

    /// Scenario modeled after Wolf Granny Square's Border round: the `(2dc, ch3, 2dc)`
    /// repeat is compiled so every inner action shares the repeat body's structural
    /// sourceText, and after the repeat a flat `(2dc, ch3)` tail emits actions with
    /// short sourceTexts `"2dc"` and `"ch3"`. Forward-scan must advance the cursor past
    /// the repeat phrase and land on the tail occurrences rather than re-hitting the
    /// first `2dc` / `ch3` at the top of the instruction.
    func testHighlightResolverAdvancesThroughAmbiguousTailAfterRepeat() {
        let raw = "Ch3 (count as 1dc), 1dc in each st around, (2dc, ch3, 2dc) in each corner as you go. When you return, work (2dc, ch3), slst."

        let chopen = AtomicAction(
            semantics: .stitchProducing,
            actionTag: "ch", stitchTag: "ch",
            producedStitches: 3,
            sourceText: "Ch3 (count as 1dc)",
            sequenceIndex: 0
        )
        let baseDc = AtomicAction(
            semantics: .stitchProducing,
            actionTag: "dc", stitchTag: "dc",
            producedStitches: 1,
            sourceText: "1dc in each st around",
            sequenceIndex: 1
        )
        // 3 actions inside the repeat; all share the repeat body phrase.
        let repeatBodyPhrase = "(2dc, ch3, 2dc) in each corner as you go"
        let repeatDc1 = AtomicAction(
            semantics: .stitchProducing, actionTag: "dc", stitchTag: "dc",
            producedStitches: 1, sourceText: repeatBodyPhrase, sequenceIndex: 2
        )
        let repeatCh = AtomicAction(
            semantics: .stitchProducing, actionTag: "ch", stitchTag: "ch",
            producedStitches: 1, sourceText: repeatBodyPhrase, sequenceIndex: 3
        )
        let repeatDc2 = AtomicAction(
            semantics: .stitchProducing, actionTag: "dc", stitchTag: "dc",
            producedStitches: 1, sourceText: repeatBodyPhrase, sequenceIndex: 4
        )
        // Tail flat statements with ambiguous short sourceTexts.
        let tailDc = AtomicAction(
            semantics: .stitchProducing, actionTag: "dc", stitchTag: "dc",
            producedStitches: 1, sourceText: "2dc", sequenceIndex: 5
        )
        let tailCh = AtomicAction(
            semantics: .stitchProducing, actionTag: "ch", stitchTag: "ch",
            producedStitches: 1, sourceText: "ch3", sequenceIndex: 6
        )
        let ordered = [chopen, baseDc, repeatDc1, repeatCh, repeatDc2, tailDc, tailCh]

        // Repeat-interior actions all resolve to the repeat body phrase.
        let repeatPhraseRange = (raw as NSString).range(of: repeatBodyPhrase)
        XCTAssertEqual(
            HighlightRangeResolver.resolveNSRange(currentActionID: repeatDc1.id, orderedActions: ordered, rawInstruction: raw),
            repeatPhraseRange
        )
        XCTAssertEqual(
            HighlightRangeResolver.resolveNSRange(currentActionID: repeatCh.id, orderedActions: ordered, rawInstruction: raw),
            repeatPhraseRange
        )
        XCTAssertEqual(
            HighlightRangeResolver.resolveNSRange(currentActionID: repeatDc2.id, orderedActions: ordered, rawInstruction: raw),
            repeatPhraseRange
        )

        // Tail 2dc must land on the `(2dc, ch3)` AFTER the repeat phrase, not the
        // first `2dc` inside `(2dc, ch3, 2dc)`.
        let tailDcRange = HighlightRangeResolver.resolveNSRange(
            currentActionID: tailDc.id, orderedActions: ordered, rawInstruction: raw
        )
        XCTAssertNotNil(tailDcRange)
        let tailScanStart = repeatPhraseRange.location + repeatPhraseRange.length
        XCTAssertGreaterThanOrEqual(tailDcRange!.location, tailScanStart)

        // Tail ch3 advances past tail 2dc.
        let tailChRange = HighlightRangeResolver.resolveNSRange(
            currentActionID: tailCh.id, orderedActions: ordered, rawInstruction: raw
        )
        XCTAssertNotNil(tailChRange)
        XCTAssertGreaterThan(tailChRange!.location, tailDcRange!.location)
    }

    /// When a parent-like action's sourceText covers a larger phrase and the next
    /// action's sourceText is a substring inside that range, the resolver must
    /// highlight the **nested** substring (inside the previous range), not scan
    /// forward past it. Mirrors the Wolf Granny Square tail bug where the DC
    /// action carried the full `(2dc+ch3)` phrase and the following CH action's
    /// sourceText `"ch3"` must land inside that same parenthesized group.
    func testHighlightResolverFindsChildSourceTextInsidePreviousRange() {
        let raw = "Ch3, (2dc, ch3, 2dc) in each corner. When you return, work (2dc+ch3), slst to the first ch3."
        let parentDc = AtomicAction(
            semantics: .stitchProducing, actionTag: "dc", stitchTag: "dc",
            producedStitches: 2, sourceText: "(2dc+ch3)", sequenceIndex: 0
        )
        let childCh = AtomicAction(
            semantics: .stitchProducing, actionTag: "ch", stitchTag: "ch",
            producedStitches: 3, sourceText: "ch3", sequenceIndex: 1
        )
        let ordered = [parentDc, childCh]

        let parentRange = HighlightRangeResolver.resolveNSRange(
            currentActionID: parentDc.id, orderedActions: ordered, rawInstruction: raw
        )
        XCTAssertEqual(parentRange, (raw as NSString).range(of: "(2dc+ch3)"))

        let childRange = HighlightRangeResolver.resolveNSRange(
            currentActionID: childCh.id, orderedActions: ordered, rawInstruction: raw
        )
        XCTAssertNotNil(childRange)
        // Must be INSIDE the parent's parenthesized phrase, not the first `ch3`
        // in `(2dc, ch3, 2dc)` and not the trailing `first ch3`.
        let parentStart = parentRange!.location
        let parentEnd = parentRange!.location + parentRange!.length
        XCTAssertGreaterThanOrEqual(childRange!.location, parentStart)
        XCTAssertLessThanOrEqual(childRange!.location + childRange!.length, parentEnd)
    }

    /// When an action has nil `sourceText`, it should not advance the cursor and should
    /// produce no highlight, but subsequent actions must still resolve correctly.
    func testHighlightResolverSkipsActionsWithNilSourceText() {
        let raw = "Ch3, 1dc, 2dc."
        let first = AtomicAction(
            semantics: .stitchProducing, actionTag: "ch", stitchTag: "ch",
            producedStitches: 3, sourceText: "Ch3", sequenceIndex: 0
        )
        let middle = AtomicAction(
            semantics: .bookkeeping, actionTag: "note",
            producedStitches: 0, sourceText: nil, sequenceIndex: 1
        )
        let last = AtomicAction(
            semantics: .stitchProducing, actionTag: "dc", stitchTag: "dc",
            producedStitches: 2, sourceText: "2dc", sequenceIndex: 2
        )
        let ordered = [first, middle, last]

        XCTAssertNil(HighlightRangeResolver.resolveNSRange(
            currentActionID: middle.id, orderedActions: ordered, rawInstruction: raw
        ))
        let lastRange = HighlightRangeResolver.resolveNSRange(
            currentActionID: last.id, orderedActions: ordered, rawInstruction: raw
        )
        XCTAssertEqual(lastRange, (raw as NSString).range(of: "2dc"))
    }

    /// Nested repeats anchor to the nearest non-nil body sourceText. If an inner repeat
    /// body has no sourceText of its own, actions fall through to the outer repeat's
    /// body sourceText — not to the leaf statement sourceText.
    func testCompilerNestedRepeatsInheritNearestBodySourceText() throws {
        let innerRepeat = CrochetIRStatement(
            kind: .repeatBlock(CrochetIRRepeatBlock(
                times: 2,
                body: CrochetIRBlock(
                    statements: [
                        CrochetIRStatement(
                            kind: .operation(CrochetIROperation(
                                semantics: .stitchProducing,
                                actionTag: "sc",
                                stitch: "sc",
                                count: 1
                            )),
                            sourceText: "sc"
                        )
                    ]
                    // inner body.sourceText intentionally nil
                )
            )),
            sourceText: "(sc, sc)"
        )
        let outerRepeat = CrochetIRStatement(
            kind: .repeatBlock(CrochetIRRepeatBlock(
                times: 3,
                body: CrochetIRBlock(
                    statements: [innerRepeat],
                    sourceText: "outer body phrase"
                )
            )),
            sourceText: "[outer body phrase] × 3"
        )
        let block = CrochetIRInstructionBlock(
            title: "Nested repeat inheritance",
            sourceText: "nested",
            body: CrochetIRBlock(statements: [outerRepeat])
        )

        let expansion = try CrochetIRCompiler().expand(block)

        // 3 outer × 2 inner × 1 sc per iter = 6 actions
        XCTAssertEqual(expansion.atomicActions.count, 6)
        XCTAssertTrue(
            expansion.atomicActions.allSatisfy { $0.sourceText == "outer body phrase" },
            "Inner repeat without its own body sourceText should inherit the outer repeat's body sourceText."
        )
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

    private func sampleAtomizationMatchEvaluationInput() -> AtomizationMatchEvaluationInput {
        AtomizationMatchEvaluationInput(
            roundTitle: "Round 3",
            rawInstruction: "sc around. (9)",
            roundSummary: "Work one single crochet in each stitch around.",
            targetStitchCount: 9,
            irSourceText: "sc around. (9)",
            expectedProducedStitches: 9,
            validationIssues: [],
            expansionFailure: nil,
            producedStitchCount: 9,
            warnings: [],
            atomicActions: (0..<9).map { index in
                AtomizationEvaluationActionInput(action: AtomicAction(
                    semantics: .stitchProducing,
                    actionTag: "sc",
                    stitchTag: "sc",
                    instruction: "sc",
                    producedStitches: 1,
                    sequenceIndex: index
                ))
            }
        )
    }

    private func sampleAtomizationMatchEvaluation() -> AtomizationMatchEvaluation {
        AtomizationMatchEvaluation(
            roundTitle: "Round 3",
            rawInstruction: "sc around. (9)",
            verdict: .normalizedMatch,
            confidence: 0.96,
            issueCodes: [],
            missingElements: [],
            extraElements: [],
            rationale: "The atomic actions preserve the instruction semantically by expanding the around directive into repeated single crochet actions."
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

// MARK: - IR fixture: real LLM end-to-end tests over a suite of patterns
//
// For each checked-in pattern under `CrochetPalTests/Fixtures/LLM/<PatternName>/` we
// capture a real LLM round-trip once (via `testCaptureAllIRFixturesFromRealLLM`), save
// the outline + IR JSON, and then run offline structural tests that iterate every
// captured pattern. The offline tests guard:
//
// 1. Every round from the outline has a corresponding IR block.
// 2. Each IR block decodes with the current Swift schema.
// 3. No legacy `lastIterationTransform` field survives.
// 4. Each operation has required fields (semantics, actionTag, stitch where expected).
// 5. Each round either validates cleanly AND expands to atomic actions, or reports
//    only "LLM quality" validator errors (never structural-invariant violations).
//
// The suite is the regression safety net for the IR pipeline — whenever the LLM
// schema / prompt changes, `rm -r Fixtures/LLM/<Name>/{outline,ir}*.json` and re-run
// the capture test to refresh.
final class IRAtomizationLLMIntegrationTests: XCTestCase {
    /// A captured pattern fixture on disk — either a web HTML snapshot or a PDF-extracted
    /// plain-text snapshot serves as the raw input. `sourceURL` is optional metadata for
    /// logging; HTML extraction doesn't actually fetch anything remotely.
    private struct PatternFixture {
        let name: String
        let rawSource: RawSource
        let sourceURL: URL?

        enum RawSource {
            case html(String)
            case plainText(String)
        }
    }

    private enum FixtureSourceType: String, Codable {
        case pdf
        case web
    }

    private struct FixtureManifest: Codable {
        var fixtures: [FixtureManifestEntry]
    }

    private struct FixtureManifestEntry: Codable {
        var name: String
        var title: String
        var sourceType: FixtureSourceType
        var sourceFiles: [String]?
        var sourceURL: String?
    }

    private struct AtomicRoundSnapshot: Codable, Hashable {
        var rounds: [AtomicRoundSnapshotEntry]
    }

    private struct AtomicRoundSnapshotEntry: Codable, Hashable {
        var title: String
        var sourceText: String
        var expectedProducedStitches: Int?
        var validationIssues: [CrochetIRValidationIssue]
        var expansionFailure: String?
        var producedStitchCount: Int?
        var warnings: [CrochetIRExpansionWarning]
        var actions: [AtomicActionSnapshot]
    }

    private struct AtomicActionSnapshot: Codable, Hashable {
        var semantics: CrochetIROperationSemantics
        var actionTag: String
        var stitchTag: String?
        var instruction: String?
        var producedStitches: Int
        var note: String?
        var sequenceIndex: Int
    }

    private struct AtomizationMatchEvaluationFixture: Codable, Hashable {
        var rounds: [AtomizationMatchEvaluation]
    }

    private static let fixturesRoot = "Fixtures/LLM"
    private static let fixtureManifestPath = "\(fixturesRoot)/fixture_manifest.json"
    private static let atomicSnapshotFileName = "atomic_rounds.json"
    private static let atomizationEvaluationFileName = "atomization_match_evaluation.json"
    private static let captureRoundBatchConcurrency = 4
    private static let captureEvaluationBatchConcurrency = 1
    private static let captureEvaluationMaxAttempts = 3

    /// Structural invariants that the IR refactor was specifically about. These MUST NOT
    /// fail on any captured pattern — they are about the schema/compiler contract, not
    /// about LLM output quality.
    private static let structuralInvariantCodes: Set<String> = [
        "ir_iteration_specific_exception_not_normalized",
        "ir_conditional_choice_id_mismatch"
    ]

    private static func loadFixtureManifest() throws -> FixtureManifest {
        guard let data = fixtureData(at: fixtureManifestPath) else {
            throw NSError(
                domain: "IRAtomizationLLMIntegrationTests",
                code: -100,
                userInfo: [NSLocalizedDescriptionKey: "missing fixture manifest at \(fixtureManifestPath)"]
            )
        }
        return try JSONDecoder().decode(FixtureManifest.self, from: data)
    }

    /// testCaptureAllIRFixturesFromRealLLM fixture discovery — enumerates every fixture
    /// declared in `fixture_manifest.json`, loads its raw source snapshot, and preserves
    /// the original URL metadata for HTML extraction.
    private static func discoverFixtures() throws -> [PatternFixture] {
        let manifest = try loadFixtureManifest()

        var result: [PatternFixture] = []
        for entry in manifest.fixtures {
            let subdir = fixtureURL(at: "\(fixturesRoot)/\(entry.name)")
            let htmlURL = subdir.appendingPathComponent("raw.html")
            let txtURL = subdir.appendingPathComponent("raw.txt")
            let source: PatternFixture.RawSource
            if let html = try? String(contentsOf: htmlURL, encoding: .utf8) {
                source = .html(html)
            } else if let text = try? String(contentsOf: txtURL, encoding: .utf8) {
                source = .plainText(text)
            } else {
                throw NSError(
                    domain: "IRAtomizationLLMIntegrationTests",
                    code: -101,
                    userInfo: [NSLocalizedDescriptionKey: "fixture \(entry.name) is missing raw.html/raw.txt"]
                )
            }

            let sourceURL = entry.sourceURL.flatMap(URL.init(string:))
            result.append(PatternFixture(name: entry.name, rawSource: source, sourceURL: sourceURL))
        }
        return result
    }

    func testFixtureDatasetIsCompleteForAllManifestEntries() throws {
        let manifest = try Self.loadFixtureManifest()
        XCTAssertFalse(manifest.fixtures.isEmpty, "fixture manifest must not be empty")
        XCTAssertEqual(
            Set(manifest.fixtures.map(\.name)).count,
            manifest.fixtures.count,
            "fixture manifest contains duplicate fixture names"
        )

        for entry in manifest.fixtures {
            let fixtureDir = "\(Self.fixturesRoot)/\(entry.name)"
            switch entry.sourceType {
            case .pdf:
                XCTAssertNotNil(
                    Self.fixtureData(at: "\(fixtureDir)/raw.txt"),
                    "[\(entry.name)] PDF fixture must persist raw.txt"
                )
                XCTAssertFalse(
                    (entry.sourceFiles ?? []).isEmpty,
                    "[\(entry.name)] PDF fixture must record at least one source filename"
                )
            case .web:
                XCTAssertNotNil(
                    Self.fixtureData(at: "\(fixtureDir)/raw.html"),
                    "[\(entry.name)] web fixture must persist raw.html"
                )
                XCTAssertNotNil(entry.sourceURL, "[\(entry.name)] web fixture must record sourceURL")
            }

            XCTAssertNotNil(
                Self.fixtureData(at: "\(fixtureDir)/outline.json"),
                "[\(entry.name)] outline.json missing"
            )
            XCTAssertNotNil(
                Self.fixtureData(at: "\(fixtureDir)/ir_atomization.json"),
                "[\(entry.name)] ir_atomization.json missing"
            )
            XCTAssertNotNil(
                Self.fixtureData(at: "\(fixtureDir)/\(Self.atomicSnapshotFileName)"),
                "[\(entry.name)] \(Self.atomicSnapshotFileName) missing"
            )
            XCTAssertNotNil(
                Self.fixtureData(at: "\(fixtureDir)/\(Self.atomizationEvaluationFileName)"),
                "[\(entry.name)] \(Self.atomizationEvaluationFileName) missing"
            )
        }
    }

    /// Decodes every captured IR JSON and runs validate + expand for every round. Rounds
    /// that report LLM-quality errors (e.g. `ir_invalid_operation_count`) are counted but
    /// not test failures — they would trigger repair in production. Structural-invariant
    /// violations ARE test failures (they would mean the refactor regressed).
    func testAllCapturedIRFixturesCanonicalAndCompile() throws {
        let fixtures = try Self.discoverFixtures()
        XCTAssertFalse(fixtures.isEmpty, "No fixture directories found under \(Self.fixturesRoot)")

        var report: [(pattern: String, valid: Int, total: Int, failures: [(String, [String])])] = []
        var testedCount = 0

        for fixture in fixtures {
            guard let data = Self.fixtureData(at: "\(Self.fixturesRoot)/\(fixture.name)/ir_atomization.json") else {
                // Not captured yet — skip and surface in the final report so the suite
                // makes the missing coverage obvious.
                report.append((fixture.name, 0, 0, [("<missing capture>", ["ir_atomization.json missing"])]))
                continue
            }
            testedCount += 1
            let response = try JSONDecoder().decode(CrochetIRAtomizationResponse.self, from: data)
            XCTAssertFalse(response.rounds.isEmpty, "[\(fixture.name)] captured fixture contains zero rounds")

            let compiler = CrochetIRCompiler()
            var validRounds = 0
            var failures: [(String, [String])] = []

            for block in response.rounds {
                let validationReport = compiler.validate(block)
                let errors = validationReport.issues.filter { $0.severity == .error }

                // Structural invariants are hard requirements.
                let structural = errors.filter { Self.structuralInvariantCodes.contains($0.code) }
                XCTAssertTrue(
                    structural.isEmpty,
                    "[\(fixture.name)] Round '\(block.title)' violates structural invariant: \(structural.map(\.code).joined(separator: ", "))"
                )

                if errors.isEmpty {
                    // expand() throws for LLM-quality issues like count<=0; catch and demote
                    // to the failures list so the run is still informative.
                    do {
                        let expansion = try compiler.expand(block)
                        // Zero-action rounds are acceptable for prose-only rounds
                        // (e.g. "Weave in ends", assembly notes) whose body is a note or
                        // an empty statement list. Only assert non-empty if the round's
                        // IR actually contains stitch-producing/increase/decrease operations.
                        let hasStitchOperations = blockContainsStitchOperations(block.body)
                        if hasStitchOperations {
                            XCTAssertFalse(
                                expansion.atomicActions.isEmpty,
                                "[\(fixture.name)] Round '\(block.title)' has stitch operations but compiled to zero actions"
                            )
                        }
                        validRounds += 1
                    } catch {
                        failures.append((block.title, ["expand_failed: \(error)"]))
                    }
                } else {
                    failures.append((block.title, errors.map(\.code)))
                }
            }

            report.append((fixture.name, validRounds, response.rounds.count, failures))
        }

        // Print a compact regression-friendly summary so runs can be diffed in CI.
        print("\n[IR fixture suite] \(testedCount) pattern(s) covered:")
        for item in report {
            let status = item.total == 0 ? "MISSING" : "\(item.valid)/\(item.total) OK"
            print("  - \(item.pattern): \(status)")
            if !item.failures.isEmpty {
                for (round, codes) in item.failures {
                    print("      · Round '\(round)': \(codes.joined(separator: ", "))")
                }
            }
        }
    }

    /// Cross-check: the outline's flattened round list should have the same count as the
    /// IR response's rounds list, and titles should align. Otherwise the atomization is
    /// dropping coverage and users will get rounds with no step-by-step instructions.
    func testAllCapturedFixturesHaveOneIRBlockPerOutlineRound() throws {
        let fixtures = try Self.discoverFixtures()

        for fixture in fixtures {
            let fixtureSuffix = "\(Self.fixturesRoot)/\(fixture.name)"
            guard let outlineData = Self.fixtureData(at: "\(fixtureSuffix)/outline.json"),
                  let irData = Self.fixtureData(at: "\(fixtureSuffix)/ir_atomization.json") else {
                // Skip missing — discovery test above surfaces this.
                continue
            }
            let outline = try JSONDecoder().decode(PatternOutlineResponse.self, from: outlineData)
            let ir = try JSONDecoder().decode(CrochetIRAtomizationResponse.self, from: irData)

            let flatOutlineTitles = outline.parts.flatMap { $0.rounds.map(\.title) }
            let irTitles = ir.rounds.map(\.title)

            XCTAssertEqual(
                flatOutlineTitles.count,
                irTitles.count,
                "[\(fixture.name)] outline rounds (\(flatOutlineTitles.count)) != IR rounds (\(irTitles.count)). Outline: \(flatOutlineTitles). IR: \(irTitles)"
            )

            // Titles should correspond 1:1 (order-preserving). We don't require exact
            // string equality because the LLM may tidy case/punctuation in the IR's title
            // — but the sets should at least be of equal size and in the same order region.
            for (i, (outlineTitle, irTitle)) in zip(flatOutlineTitles, irTitles).enumerated() {
                XCTAssertFalse(
                    outlineTitle.isEmpty || irTitle.isEmpty,
                    "[\(fixture.name)] empty title at index \(i): outline='\(outlineTitle)' ir='\(irTitle)'"
                )
            }
        }
    }

    func testAllCapturedFixturesMatchPersistedAtomicSnapshots() throws {
        let fixtures = try Self.discoverFixtures()

        for fixture in fixtures {
            let fixtureSuffix = "\(Self.fixturesRoot)/\(fixture.name)"
            guard let outlineData = Self.fixtureData(at: "\(fixtureSuffix)/outline.json"),
                  let irData = Self.fixtureData(at: "\(fixtureSuffix)/ir_atomization.json"),
                  let snapshotData = Self.fixtureData(at: "\(fixtureSuffix)/\(Self.atomicSnapshotFileName)") else {
                return XCTFail("[\(fixture.name)] missing outline / IR / atomic snapshot fixture")
            }

            let outline = try JSONDecoder().decode(PatternOutlineResponse.self, from: outlineData)
            let ir = try JSONDecoder().decode(CrochetIRAtomizationResponse.self, from: irData)
            let expectedSnapshot = try JSONDecoder().decode(AtomicRoundSnapshot.self, from: snapshotData)
            let actualSnapshot = try Self.buildAtomicRoundSnapshot(from: ir)

            XCTAssertEqual(
                outline.parts.flatMap(\.rounds).count,
                expectedSnapshot.rounds.count,
                "[\(fixture.name)] outline round count must match persisted atomic snapshot count"
            )
            XCTAssertEqual(
                ir.rounds.count,
                expectedSnapshot.rounds.count,
                "[\(fixture.name)] IR round count must match persisted atomic snapshot count"
            )
            XCTAssertEqual(
                actualSnapshot,
                expectedSnapshot,
                "[\(fixture.name)] compiled atomic snapshot diverged from persisted regression data"
            )
        }
    }

    func testAllCapturedAtomizationMatchEvaluationsCoverEveryRound() throws {
        let fixtures = try Self.discoverFixtures()

        for fixture in fixtures {
            let fixtureSuffix = "\(Self.fixturesRoot)/\(fixture.name)"
            guard let outlineData = Self.fixtureData(at: "\(fixtureSuffix)/outline.json"),
                  let snapshotData = Self.fixtureData(at: "\(fixtureSuffix)/\(Self.atomicSnapshotFileName)"),
                  let evaluationData = Self.fixtureData(at: "\(fixtureSuffix)/\(Self.atomizationEvaluationFileName)") else {
                return XCTFail("[\(fixture.name)] missing outline / atomic snapshot / evaluation fixture")
            }

            let outline = try JSONDecoder().decode(PatternOutlineResponse.self, from: outlineData)
            let snapshot = try JSONDecoder().decode(AtomicRoundSnapshot.self, from: snapshotData)
            let evaluations = try JSONDecoder().decode(AtomizationMatchEvaluationFixture.self, from: evaluationData)
            let flatOutlineRounds = outline.parts.flatMap(\.rounds)

            XCTAssertEqual(
                flatOutlineRounds.count,
                evaluations.rounds.count,
                "[\(fixture.name)] outline round count must match evaluation round count"
            )
            XCTAssertEqual(
                snapshot.rounds.count,
                evaluations.rounds.count,
                "[\(fixture.name)] atomic snapshot round count must match evaluation round count"
            )

            for (index, pair) in zip(flatOutlineRounds, evaluations.rounds).enumerated() {
                let (outlineRound, evaluation) = pair
                XCTAssertEqual(
                    outlineRound.title,
                    evaluation.roundTitle,
                    "[\(fixture.name)] evaluation round title mismatch at index \(index)"
                )
                XCTAssertEqual(
                    outlineRound.rawInstruction,
                    evaluation.rawInstruction,
                    "[\(fixture.name)] evaluation rawInstruction mismatch at index \(index)"
                )
            }
        }
    }

    func testAllCapturedAtomizationMatchEvaluationsRespectInvariants() throws {
        let fixtures = try Self.discoverFixtures()
        var verdictCounts: [AtomizationMatchVerdict: Int] = [:]

        for fixture in fixtures {
            let fixtureSuffix = "\(Self.fixturesRoot)/\(fixture.name)"
            guard let evaluationData = Self.fixtureData(at: "\(fixtureSuffix)/\(Self.atomizationEvaluationFileName)") else {
                continue
            }

            let evaluations = try JSONDecoder().decode(AtomizationMatchEvaluationFixture.self, from: evaluationData)
            for evaluation in evaluations.rounds {
                verdictCounts[evaluation.verdict, default: 0] += 1

                XCTAssertFalse(evaluation.roundTitle.isEmpty, "[\(fixture.name)] evaluation roundTitle must not be empty")
                XCTAssertFalse(evaluation.rawInstruction.isEmpty, "[\(fixture.name)] evaluation rawInstruction must not be empty")
                XCTAssertFalse(evaluation.rationale.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "[\(fixture.name)] evaluation rationale must not be empty")
                XCTAssertGreaterThanOrEqual(evaluation.confidence, 0, "[\(fixture.name)] evaluation confidence must be >= 0")
                XCTAssertLessThanOrEqual(evaluation.confidence, 1, "[\(fixture.name)] evaluation confidence must be <= 1")

                switch evaluation.verdict {
                case .exactMatch, .normalizedMatch:
                    XCTAssertTrue(evaluation.issueCodes.isEmpty, "[\(fixture.name)] \(evaluation.roundTitle) should not report issue codes for a passing verdict")
                    XCTAssertTrue(evaluation.missingElements.isEmpty, "[\(fixture.name)] \(evaluation.roundTitle) should not report missing elements for a passing verdict")
                    XCTAssertTrue(evaluation.extraElements.isEmpty, "[\(fixture.name)] \(evaluation.roundTitle) should not report extra elements for a passing verdict")
                case .partialMatch, .mismatch:
                    XCTAssertTrue(
                        !evaluation.issueCodes.isEmpty || !evaluation.missingElements.isEmpty || !evaluation.extraElements.isEmpty,
                        "[\(fixture.name)] \(evaluation.roundTitle) must provide concrete evidence for a failing verdict"
                    )
                case .notActionable:
                    break
                }
            }
        }

        print("\n[Atomization evaluator verdicts]")
        for verdict in AtomizationMatchVerdict.allCases {
            print("  - \(verdict.rawValue): \(verdictCounts[verdict, default: 0])")
        }
    }

    /// Checks the schema invariants that the refactor guaranteed: no legacy field, every
    /// operation has actionTag + correct stitch presence, every repeat/conditional body
    /// is well-formed. Applied to every captured fixture.
    func testAllCapturedIRFixturesRespectInvariants() throws {
        let fixtures = try Self.discoverFixtures()

        for fixture in fixtures {
            guard let data = Self.fixtureData(at: "\(Self.fixturesRoot)/\(fixture.name)/ir_atomization.json") else {
                continue
            }

            let rawText = String(decoding: data, as: UTF8.self)
            XCTAssertFalse(
                rawText.contains("lastIterationTransform"),
                "[\(fixture.name)] captured IR must not carry the removed lastIterationTransform field."
            )

            let response = try JSONDecoder().decode(CrochetIRAtomizationResponse.self, from: data)
            for round in response.rounds {
                assertBlockInvariants(round.body, context: "\(fixture.name) > \(round.title)")
            }
        }
    }

    /// Returns true if the block (or any nested block) contains any operation with
    /// stitch-producing semantics. Used to decide whether the round is expected to expand
    /// to non-zero AtomicActions.
    private func blockContainsStitchOperations(_ block: CrochetIRBlock) -> Bool {
        for statement in block.statements {
            switch statement.kind {
            case let .operation(op):
                if op.semantics == .stitchProducing || op.semantics == .increase || op.semantics == .decrease {
                    return true
                }
            case let .repeatBlock(rb):
                if blockContainsStitchOperations(rb.body) { return true }
            case let .conditional(c):
                for branch in c.branches where blockContainsStitchOperations(branch.body) { return true }
                if let common = c.commonBody, blockContainsStitchOperations(common) { return true }
            case .note:
                break
            }
        }
        return false
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
                // rb.times<=0 and rb.body.statements.isEmpty are caught by the compiler
                // validator (`ir_invalid_repeat_times` / `ir_empty_repeat_body`). We log
                // them in the canonical-and-compile test rather than re-assert here, so
                // LLM-quality misses don't fail this invariant-only test.
                if rb.times > 0 && !rb.body.statements.isEmpty {
                    assertBlockInvariants(rb.body, context: "\(context) > repeat")
                }
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

    private static func buildAtomicRoundSnapshot(from ir: CrochetIRAtomizationResponse) throws -> AtomicRoundSnapshot {
        let compiler = CrochetIRCompiler()
        let rounds = try ir.rounds.map { block in
            let validationReport = compiler.validate(block)
            let errors = validationReport.issues.filter { $0.severity == .error }

            guard errors.isEmpty else {
                return AtomicRoundSnapshotEntry(
                    title: block.title,
                    sourceText: block.sourceText,
                    expectedProducedStitches: block.expectedProducedStitches,
                    validationIssues: validationReport.issues,
                    expansionFailure: nil,
                    producedStitchCount: nil,
                    warnings: [],
                    actions: []
                )
            }

            do {
                let expansion = try compiler.expand(block)
                return AtomicRoundSnapshotEntry(
                    title: block.title,
                    sourceText: block.sourceText,
                    expectedProducedStitches: block.expectedProducedStitches,
                    validationIssues: validationReport.issues,
                    expansionFailure: nil,
                    producedStitchCount: expansion.producedStitchCount,
                    warnings: expansion.warnings,
                    actions: expansion.atomicActions.map { action in
                        AtomicActionSnapshot(
                            semantics: action.semantics,
                            actionTag: action.actionTag,
                            stitchTag: action.stitchTag,
                            instruction: action.instruction,
                            producedStitches: action.producedStitches,
                            note: action.note,
                            sequenceIndex: action.sequenceIndex
                        )
                    }
                )
            } catch {
                return AtomicRoundSnapshotEntry(
                    title: block.title,
                    sourceText: block.sourceText,
                    expectedProducedStitches: block.expectedProducedStitches,
                    validationIssues: validationReport.issues,
                    expansionFailure: String(describing: error),
                    producedStitchCount: nil,
                    warnings: [],
                    actions: []
                )
            }
        }
        return AtomicRoundSnapshot(rounds: rounds)
    }

    /// REFRESH STEP — only runs when the sentinel file
    /// `/tmp/crochet/REFRESH_ATOMIC_SNAPSHOTS` exists. Rebuilds `atomic_rounds.json`
    /// from persisted `ir_atomization.json` without calling the model.
    func testRefreshAtomicSnapshotsFromPersistedIR() throws {
        let sentinelURL = URL(fileURLWithPath: "/tmp/crochet/REFRESH_ATOMIC_SNAPSHOTS")
        guard FileManager.default.fileExists(atPath: sentinelURL.path) else {
            throw XCTSkip("Atomic snapshot refresh disabled. `touch /tmp/crochet/REFRESH_ATOMIC_SNAPSHOTS` to enable.")
        }

        let selectedFixturesURL = URL(fileURLWithPath: "/tmp/crochet/CAPTURE_FIXTURE_NAMES")
        let selectedFixtureNames: Set<String>? = {
            let rawText = (try? String(contentsOf: selectedFixturesURL, encoding: .utf8))
                ?? ProcessInfo.processInfo.environment["CAPTURE_FIXTURE_NAMES"]
                ?? ""
            let rawValue = rawText
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return rawValue.isEmpty ? nil : Set(rawValue)
        }()

        let fixtures = try Self.discoverFixtures()
        XCTAssertFalse(fixtures.isEmpty, "No fixture directories under \(Self.fixturesRoot)")

        var refreshed = 0
        var skipped = 0
        var failures: [(String, String)] = []

        for fixture in fixtures {
            if let selectedFixtureNames, !selectedFixtureNames.contains(fixture.name) {
                skipped += 1
                print("[refresh-snapshot] \(fixture.name): skipped by fixture filter")
                continue
            }

            let fixtureDir = "\(Self.fixturesRoot)/\(fixture.name)"
            let irPath = "\(fixtureDir)/ir_atomization.json"
            let atomicSnapshotPath = "\(fixtureDir)/\(Self.atomicSnapshotFileName)"

            do {
                let irData = try XCTUnwrap(
                    Self.fixtureData(at: irPath),
                    "[\(fixture.name)] missing persisted IR fixture"
                )
                let ir = try JSONDecoder().decode(CrochetIRAtomizationResponse.self, from: irData)
                let snapshot = try Self.buildAtomicRoundSnapshot(from: ir)
                try Self.writePrettyJSON(snapshot, to: atomicSnapshotPath)
                refreshed += 1
                print("[refresh-snapshot] \(fixture.name): wrote \(snapshot.rounds.count) atomic rounds")
            } catch {
                failures.append((fixture.name, "\(error)"))
                print("[refresh-snapshot] \(fixture.name): FAILED — \(error)")
            }
        }

        print("\n[refresh-snapshot summary] refreshed=\(refreshed) skipped=\(skipped) failed=\(failures.count)")
        if !failures.isEmpty {
            let details = failures.map { "\($0.0): \($0.1)" }.joined(separator: "\n")
            XCTFail("Atomic snapshot refresh failures:\n\(details)")
        }
    }

    /// CAPTURE STEP — only runs when the sentinel file `/tmp/crochet/CAPTURE_IR` exists.
    /// Reads credentials from `Config/Secrets.xcconfig`, iterates every subdirectory under
    /// `CrochetPalTests/Fixtures/LLM/`, and for each one that has a `raw.html` / `raw.txt`
    /// and is missing `outline.json` or `ir_atomization.json`, runs the real LLM pipeline
    /// and writes outline + IR JSON back to disk. If the LLM capture already exists but
    /// `atomic_rounds.json` is missing, it deterministically rebuilds the compiled atomic
    /// snapshot from the persisted IR without calling the model. If the sentinel file
    /// `/tmp/crochet/REFRESH_ALL_IR_FIXTURES` exists, every fixture is re-captured from
    /// scratch regardless of existing generated JSON.
    ///
    /// - To refresh a specific fixture: delete that fixture's generated JSON files and re-run.
    /// - To refresh all: delete the generated JSON files under `Fixtures/LLM/<Name>/` and re-run.
    ///
    /// Uses raw HTTP (not `OpenAICompatibleLLMClient.sendChatCompletion`) so the raw
    /// assistant content is always saved before decoding — handy when the LLM emits
    /// something that can't decode and you need to inspect it.
    func testCaptureAllIRFixturesFromRealLLM() async throws {
        let sentinelURL = URL(fileURLWithPath: "/tmp/crochet/CAPTURE_IR")
        guard FileManager.default.fileExists(atPath: sentinelURL.path) else {
            throw XCTSkip("Capture test disabled. `touch /tmp/crochet/CAPTURE_IR` to enable.")
        }
        let refreshAllURL = URL(fileURLWithPath: "/tmp/crochet/REFRESH_ALL_IR_FIXTURES")
        let forceRefreshAll = FileManager.default.fileExists(atPath: refreshAllURL.path)
        let selectedFixturesURL = URL(fileURLWithPath: "/tmp/crochet/CAPTURE_FIXTURE_NAMES")
        let selectedFixtureNames: Set<String>? = {
            let rawText = (try? String(contentsOf: selectedFixturesURL, encoding: .utf8))
                ?? ProcessInfo.processInfo.environment["CAPTURE_FIXTURE_NAMES"]
                ?? ""
            let rawValue = rawText
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return rawValue.isEmpty ? nil : Set(rawValue)
        }()

        let configuration = try Self.makeRuntimeConfigurationFromSecretsFile()
        let fixtures = try Self.discoverFixtures()
        XCTAssertFalse(fixtures.isEmpty, "No fixture directories under \(Self.fixturesRoot)")

        var captured = 0
        var rebuiltAtomicSnapshots = 0
        var skipped = 0
        var failures: [(String, String)] = []

        for fixture in fixtures {
            if let selectedFixtureNames, !selectedFixtureNames.contains(fixture.name) {
                skipped += 1
                print("[capture] \(fixture.name): skipped by fixture filter")
                continue
            }

            let fixtureDir = "\(Self.fixturesRoot)/\(fixture.name)"
            let outlinePath = "\(fixtureDir)/outline.json"
            let irPath = "\(fixtureDir)/ir_atomization.json"
            let atomicSnapshotPath = "\(fixtureDir)/\(Self.atomicSnapshotFileName)"
            let hasOutline = Self.fixtureData(at: outlinePath) != nil
            let hasIR = Self.fixtureData(at: irPath) != nil
            let hasAtomicSnapshot = Self.fixtureData(at: atomicSnapshotPath) != nil

            if forceRefreshAll || selectedFixtureNames != nil {
                do {
                    print("[capture] \(fixture.name): force refreshing outline + IR LLM calls...")
                    try await captureFixture(fixture, configuration: configuration, fixtureDir: fixtureDir)
                    captured += 1
                } catch {
                    failures.append((fixture.name, "\(error)"))
                    print("[capture] \(fixture.name): FAILED — \(error)")
                }
                continue
            }

            if hasOutline, hasIR, hasAtomicSnapshot {
                skipped += 1
                print("[capture] \(fixture.name): already captured — skipped")
                continue
            }

            do {
                if hasOutline, hasIR, !hasAtomicSnapshot {
                    let irData = try XCTUnwrap(Self.fixtureData(at: irPath))
                    let ir = try JSONDecoder().decode(CrochetIRAtomizationResponse.self, from: irData)
                    let snapshot = try Self.buildAtomicRoundSnapshot(from: ir)
                    try Self.writePrettyJSON(snapshot, to: atomicSnapshotPath)
                    rebuiltAtomicSnapshots += 1
                    print("[capture] \(fixture.name): rebuilt atomic snapshot from persisted IR")
                } else {
                    print("[capture] \(fixture.name): running outline + IR LLM calls...")
                    try await captureFixture(fixture, configuration: configuration, fixtureDir: fixtureDir)
                    captured += 1
                }
            } catch {
                failures.append((fixture.name, "\(error)"))
                print("[capture] \(fixture.name): FAILED — \(error)")
            }
        }

        print(
            "\n[capture summary] captured=\(captured) rebuiltAtomicSnapshots=\(rebuiltAtomicSnapshots) skipped=\(skipped) failed=\(failures.count)"
        )
        for (name, err) in failures {
            print("  - \(name): \(err)")
        }
        XCTAssertTrue(failures.isEmpty, "One or more patterns failed capture")
    }

    /// CAPTURE STEP — only runs when the sentinel file
    /// `/tmp/crochet/CAPTURE_ATOMIZATION_MATCH_EVAL` exists. Uses the persisted
    /// outline + IR + atomic snapshot fixtures as input and asks the evaluation
    /// subagent whether each round's compiled atomic result faithfully matches the
    /// source `rawInstruction`.
    ///
    /// If `/tmp/crochet/REFRESH_ATOMIZATION_MATCH_EVAL_FIXTURES` exists, every
    /// selected fixture is re-evaluated even if
    /// `atomization_match_evaluation.json` already exists.
    func testCaptureAllAtomizationMatchEvaluationsFromRealLLM() async throws {
        let sentinelURL = URL(fileURLWithPath: "/tmp/crochet/CAPTURE_ATOMIZATION_MATCH_EVAL")
        guard FileManager.default.fileExists(atPath: sentinelURL.path) else {
            throw XCTSkip("Capture test disabled. `touch /tmp/crochet/CAPTURE_ATOMIZATION_MATCH_EVAL` to enable.")
        }
        let refreshAllURL = URL(fileURLWithPath: "/tmp/crochet/REFRESH_ATOMIZATION_MATCH_EVAL_FIXTURES")
        let forceRefreshAll = FileManager.default.fileExists(atPath: refreshAllURL.path)
        let selectedFixturesURL = URL(fileURLWithPath: "/tmp/crochet/CAPTURE_FIXTURE_NAMES")
        let selectedFixtureNames: Set<String>? = {
            let rawText = (try? String(contentsOf: selectedFixturesURL, encoding: .utf8))
                ?? ProcessInfo.processInfo.environment["CAPTURE_FIXTURE_NAMES"]
                ?? ""
            let rawValue = rawText
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return rawValue.isEmpty ? nil : Set(rawValue)
        }()

        let configuration = try Self.makeRuntimeConfigurationFromSecretsFile()
        let fixtures = try Self.discoverFixtures()
        XCTAssertFalse(fixtures.isEmpty, "No fixture directories under \(Self.fixturesRoot)")

        var captured = 0
        var skipped = 0
        var failures: [(String, String)] = []

        for fixture in fixtures {
            if let selectedFixtureNames, !selectedFixtureNames.contains(fixture.name) {
                skipped += 1
                print("[capture-eval] \(fixture.name): skipped by fixture filter")
                continue
            }

            let fixtureDir = "\(Self.fixturesRoot)/\(fixture.name)"
            let evaluationPath = "\(fixtureDir)/\(Self.atomizationEvaluationFileName)"
            let hasEvaluation = Self.fixtureData(at: evaluationPath) != nil

            if !forceRefreshAll, selectedFixtureNames == nil, hasEvaluation {
                skipped += 1
                print("[capture-eval] \(fixture.name): already evaluated — skipped")
                continue
            }

            do {
                let outlineData = try XCTUnwrap(
                    Self.fixtureData(at: "\(fixtureDir)/outline.json"),
                    "[\(fixture.name)] missing outline.json required for evaluation capture"
                )
                let irData = try XCTUnwrap(
                    Self.fixtureData(at: "\(fixtureDir)/ir_atomization.json"),
                    "[\(fixture.name)] missing ir_atomization.json required for evaluation capture"
                )
                let snapshotData = try XCTUnwrap(
                    Self.fixtureData(at: "\(fixtureDir)/\(Self.atomicSnapshotFileName)"),
                    "[\(fixture.name)] missing \(Self.atomicSnapshotFileName) required for evaluation capture"
                )

                let outline = try JSONDecoder().decode(PatternOutlineResponse.self, from: outlineData)
                let ir = try JSONDecoder().decode(CrochetIRAtomizationResponse.self, from: irData)
                let snapshot = try JSONDecoder().decode(AtomicRoundSnapshot.self, from: snapshotData)

                let evaluations = try await captureAtomizationMatchEvaluations(
                    fixture: fixture,
                    outline: outline,
                    ir: ir,
                    atomicSnapshot: snapshot,
                    configuration: configuration
                )
                try Self.writePrettyJSON(
                    AtomizationMatchEvaluationFixture(rounds: evaluations),
                    to: evaluationPath
                )
                captured += 1
                print("[capture-eval] \(fixture.name): wrote \(evaluations.count) evaluation rounds")
            } catch {
                failures.append((fixture.name, "\(error)"))
                print("[capture-eval] \(fixture.name): FAILED — \(error)")
            }
        }

        print("\n[capture-eval summary] captured=\(captured) skipped=\(skipped) failed=\(failures.count)")
        for (name, err) in failures {
            print("  - \(name): \(err)")
        }
        XCTAssertTrue(failures.isEmpty, "One or more patterns failed evaluation capture")
    }

    private func captureFixture(
        _ fixture: PatternFixture,
        configuration: RuntimeConfiguration,
        fixtureDir: String
    ) async throws {
        let logger = ConsoleTraceLogger()
        let sourceType: PatternSourceType = switch fixture.rawSource {
        case .html: .web
        case .plainText: .text
        }
        let context = ParseRequestContext(
            traceID: "capture-\(fixture.name)-\(UUID().uuidString)",
            parseRequestID: "capture-\(UUID().uuidString)",
            sourceType: sourceType
        )
        let parserClient = OpenAICompatibleLLMClient(configuration: configuration, logger: logger)

        // Produce the extracted text for the outline prompt. HTML goes through the
        // production HTMLExtractionService so outline sees the same content it would
        // get in-app. PDF/txt sources are passed through verbatim — they're already
        // plain-text extracts.
        let extractedText: String
        let titleHint: String?
        switch fixture.rawSource {
        case .html(let html):
            let extraction = HTMLExtractionService().extract(
                from: html,
                sourceURL: fixture.sourceURL,
                context: context,
                logger: logger
            )
            XCTAssertFalse(extraction.finalText.isEmpty, "[\(fixture.name)] HTML extractor returned empty text")
            extractedText = extraction.finalText
            titleHint = extraction.title
        case .plainText(let text):
            extractedText = text
            titleHint = nil
        }
        try Self.writeText(extractedText, to: "\(fixtureDir)/extracted_text.txt")

        // ----- Step 1: outline -----
        let outlineRawPath = "\(fixtureDir)/outline_raw.json"
        let outline: PatternOutlineResponse
        do {
            let outlineContent = try await Self.fetchAssistantContent(
                configuration: configuration,
                modelID: configuration.textModelID,
                systemPrompt: PromptFactory.textOutlineSystemPrompt(),
                userPrompt: PromptFactory.textOutlinePrompt(extractedText: extractedText, titleHint: titleHint),
                responseFormat: PromptFactory.outlineResponseFormat()
            )
            try Self.writeText(outlineContent, to: outlineRawPath)
            outline = try JSONDecoder().decode(PatternOutlineResponse.self, from: Data(outlineContent.utf8))
        } catch {
            print("  [capture] \(fixture.name): outline decode failed, retrying via repair-capable client (\(error))")
            outline = try await parserClient.parseTextPatternOutline(
                extractedText: extractedText,
                titleHint: titleHint,
                context: context
            )
            try Self.writeText(try Self.jsonString(outline), to: outlineRawPath)
        }
        try Self.writePrettyJSON(outline, to: "\(fixtureDir)/outline.json")

        // ----- Step 2: IR atomization (batched) -----
        //
        // DeepSeek v3.2 (and most commercial LLMs via Cloudflare gateway) silently cap
        // output at ~8K tokens even when max_tokens says more. For large patterns the IR
        // tree easily exceeds that, so we atomize in batches matching the production
        // ProjectRepository pattern (incremental per-round atomization).
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
        guard !atomizationInputs.isEmpty else {
            throw NSError(
                domain: "CaptureIRFixture",
                code: -10,
                userInfo: [NSLocalizedDescriptionKey: "[\(fixture.name)] outline produced zero rounds"]
            )
        }

        // One source round still maps to one LLM call, but we run a few calls in parallel
        // to keep full-suite recaptures tractable after prompt changes.
        struct IndexedIRCapture {
            var index: Int
            var title: String
            var rawContent: String
        }

        var orderedCaptures = Array<IndexedIRCapture?>(repeating: nil, count: atomizationInputs.count)
        for batchStart in stride(from: 0, to: atomizationInputs.count, by: Self.captureRoundBatchConcurrency) {
            let batchEnd = min(batchStart + Self.captureRoundBatchConcurrency, atomizationInputs.count)

            try await withThrowingTaskGroup(of: IndexedIRCapture.self) { group in
                for index in batchStart..<batchEnd {
                    let input = atomizationInputs[index]
                    group.addTask {
                        let irContent = try await Self.fetchAssistantContent(
                            configuration: configuration,
                            modelID: configuration.atomizationModelID,
                            systemPrompt: PromptFactory.roundIRAtomizationSystemPrompt(),
                            userPrompt: PromptFactory.roundIRAtomizationPrompt(
                                projectTitle: outline.projectTitle,
                                materials: outline.materials,
                                rounds: [input]
                            ),
                            responseFormat: PromptFactory.irAtomizationResponseFormat()
                        )

                        return IndexedIRCapture(
                            index: index,
                            title: input.title,
                            rawContent: irContent
                        )
                    }
                }

                for try await capture in group {
                    orderedCaptures[capture.index] = capture
                    print(
                        "  [capture] \(fixture.name): round \(capture.index + 1)/\(atomizationInputs.count) '\(capture.title)' returned \(capture.rawContent.utf8.count) bytes"
                    )
                }
            }
        }

        let captures = try orderedCaptures.enumerated().map { index, capture -> IndexedIRCapture in
            guard let capture else {
                throw NSError(
                    domain: "CaptureIRFixture",
                    code: -12,
                    userInfo: [NSLocalizedDescriptionKey: "[\(fixture.name)] missing IR capture for round index \(index)"]
                )
            }
            return capture
        }
        var rawSegments: [String] = []
        var allIRRounds: [CrochetIRInstructionBlock] = []
        rawSegments.reserveCapacity(captures.count)
        allIRRounds.reserveCapacity(captures.count)

        for capture in captures {
            do {
                let batchIR = try JSONDecoder().decode(CrochetIRAtomizationResponse.self, from: Data(capture.rawContent.utf8))
                if batchIR.rounds.count != 1 {
                    throw NSError(
                        domain: "CaptureIRFixture",
                        code: -11,
                        userInfo: [NSLocalizedDescriptionKey: "[\(fixture.name)] round '\(capture.title)' expected 1 round, got \(batchIR.rounds.count)"]
                    )
                }
                rawSegments.append(capture.rawContent)
                allIRRounds.append(batchIR.rounds[0])
            } catch {
                print("  [capture] \(fixture.name): round \(capture.index + 1) '\(capture.title)' decode failed, retrying via repair-capable client (\(error))")
                let repairedIR = try await parserClient.parseTextRoundsToIR(
                    projectTitle: outline.projectTitle,
                    materials: outline.materials,
                    rounds: [atomizationInputs[capture.index]],
                    context: context
                )
                if repairedIR.rounds.count != 1 {
                    throw NSError(
                        domain: "CaptureIRFixture",
                        code: -13,
                        userInfo: [NSLocalizedDescriptionKey: "[\(fixture.name)] repaired round '\(capture.title)' expected 1 round, got \(repairedIR.rounds.count)"]
                    )
                }
                rawSegments.append(try Self.jsonString(repairedIR))
                allIRRounds.append(repairedIR.rounds[0])
            }
        }

        // Persist raw segments for debugging (newline-separated JSON blobs).
        try Self.writeText(rawSegments.joined(separator: "\n\n---\n\n"), to: "\(fixtureDir)/ir_raw.json")

        let ir = CrochetIRAtomizationResponse(rounds: allIRRounds)
        try Self.writePrettyJSON(ir, to: "\(fixtureDir)/ir_atomization.json")
        let atomicSnapshot = try Self.buildAtomicRoundSnapshot(from: ir)
        try Self.writePrettyJSON(atomicSnapshot, to: "\(fixtureDir)/\(Self.atomicSnapshotFileName)")
        print("  [capture] \(fixture.name): \(ir.rounds.count) IR rounds written (per-round batches)")
    }

    private func captureAtomizationMatchEvaluations(
        fixture: PatternFixture,
        outline: PatternOutlineResponse,
        ir: CrochetIRAtomizationResponse,
        atomicSnapshot: AtomicRoundSnapshot,
        configuration: RuntimeConfiguration
    ) async throws -> [AtomizationMatchEvaluation] {
        let inputs = try Self.buildAtomizationEvaluationInputs(
            fixtureName: fixture.name,
            outline: outline,
            ir: ir,
            snapshot: atomicSnapshot
        )

        struct IndexedEvaluationCapture: Sendable {
            var index: Int
            var title: String
            var evaluation: AtomizationMatchEvaluation
        }

        let sourceType: PatternSourceType = switch fixture.rawSource {
        case .html: .web
        case .plainText: .text
        }

        var orderedEvaluations = Array<AtomizationMatchEvaluation?>(repeating: nil, count: inputs.count)
        for batchStart in stride(from: 0, to: inputs.count, by: Self.captureEvaluationBatchConcurrency) {
            let batchEnd = min(batchStart + Self.captureEvaluationBatchConcurrency, inputs.count)

            try await withThrowingTaskGroup(of: IndexedEvaluationCapture.self) { group in
                for index in batchStart..<batchEnd {
                    let input = inputs[index]
                    group.addTask {
                        let evaluation = try await self.captureAtomizationMatchEvaluation(
                            input: input,
                            fixtureName: fixture.name,
                            roundIndex: index,
                            roundCount: inputs.count,
                            sourceType: sourceType,
                            configuration: configuration
                        )
                        return IndexedEvaluationCapture(
                            index: index,
                            title: input.roundTitle,
                            evaluation: evaluation
                        )
                    }
                }

                for try await capture in group {
                    orderedEvaluations[capture.index] = capture.evaluation
                    print(
                        "  [capture-eval] \(fixture.name): round \(capture.index + 1)/\(inputs.count) '\(capture.title)' -> \(capture.evaluation.verdict.rawValue)"
                    )
                }
            }
        }

        return try orderedEvaluations.enumerated().map { index, evaluation in
            guard let evaluation else {
                throw NSError(
                    domain: "CaptureAtomizationEvaluationFixture",
                    code: -21,
                    userInfo: [NSLocalizedDescriptionKey: "[\(fixture.name)] missing evaluation capture for round index \(index)"]
                )
            }
            return evaluation
        }
    }

    private func captureAtomizationMatchEvaluation(
        input: AtomizationMatchEvaluationInput,
        fixtureName: String,
        roundIndex: Int,
        roundCount: Int,
        sourceType: PatternSourceType,
        configuration: RuntimeConfiguration
    ) async throws -> AtomizationMatchEvaluation {
        var lastError: Error?

        for attempt in 1...Self.captureEvaluationMaxAttempts {
            do {
                let context = ParseRequestContext(
                    traceID: "capture-eval-\(fixtureName)-\(UUID().uuidString)",
                    parseRequestID: "capture-eval-\(UUID().uuidString)",
                    sourceType: sourceType
                )
                let subagent = AtomizationMatchSubagent(
                    evaluator: OpenAICompatibleLLMClient(
                        configuration: configuration,
                        logger: ConsoleTraceLogger()
                    )
                )
                return try await subagent.evaluate(input: input, context: context)
            } catch {
                lastError = error
                guard attempt < Self.captureEvaluationMaxAttempts else { break }
                print(
                    "  [capture-eval] \(fixtureName): round \(roundIndex + 1)/\(roundCount) '\(input.roundTitle)' attempt \(attempt) failed, retrying (\(error))"
                )
                try await Task.sleep(nanoseconds: UInt64(attempt) * 300_000_000)
            }
        }

        throw lastError ?? NSError(
            domain: "CaptureAtomizationEvaluationFixture",
            code: -24,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "[\(fixtureName)] missing terminal error for atomization evaluation capture on round '\(input.roundTitle)'"
            ]
        )
    }

    private static func buildAtomizationEvaluationInputs(
        fixtureName: String,
        outline: PatternOutlineResponse,
        ir: CrochetIRAtomizationResponse,
        snapshot: AtomicRoundSnapshot
    ) throws -> [AtomizationMatchEvaluationInput] {
        let flatOutlineRounds = outline.parts.flatMap(\.rounds)
        guard flatOutlineRounds.count == ir.rounds.count else {
            throw NSError(
                domain: "CaptureAtomizationEvaluationFixture",
                code: -22,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "[\(fixtureName)] outline round count \(flatOutlineRounds.count) does not match IR round count \(ir.rounds.count)"
                ]
            )
        }
        guard flatOutlineRounds.count == snapshot.rounds.count else {
            throw NSError(
                domain: "CaptureAtomizationEvaluationFixture",
                code: -23,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "[\(fixtureName)] outline round count \(flatOutlineRounds.count) does not match atomic snapshot round count \(snapshot.rounds.count)"
                ]
            )
        }

        return zip(flatOutlineRounds, zip(ir.rounds, snapshot.rounds)).map { outlineRound, pair in
            let (irRound, atomicRound) = pair
            return AtomizationMatchEvaluationInput(
                roundTitle: outlineRound.title,
                rawInstruction: outlineRound.rawInstruction,
                roundSummary: outlineRound.summary,
                targetStitchCount: outlineRound.targetStitchCount,
                irSourceText: irRound.sourceText,
                expectedProducedStitches: irRound.expectedProducedStitches,
                validationIssues: atomicRound.validationIssues,
                expansionFailure: atomicRound.expansionFailure,
                producedStitchCount: atomicRound.producedStitchCount,
                warnings: atomicRound.warnings,
                atomicActions: atomicRound.actions.map(Self.makeEvaluationActionInput(from:))
            )
        }
    }

    private static func makeEvaluationActionInput(from snapshot: AtomicActionSnapshot) -> AtomizationEvaluationActionInput {
        AtomizationEvaluationActionInput(
            semantics: snapshot.semantics,
            actionTag: snapshot.actionTag,
            stitchTag: snapshot.stitchTag,
            instruction: snapshot.instruction,
            producedStitches: snapshot.producedStitches,
            note: snapshot.note,
            sequenceIndex: snapshot.sequenceIndex
        )
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

        // max_tokens must be explicit — Cloudflare/DeepSeek defaults silently truncate
        // large outputs (multi-round IR for 50+ round patterns easily exceeds 4096).
        let body: [String: Any] = [
            "model": modelID,
            "temperature": 0,
            "max_tokens": 32000,
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

    private static func jsonString<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        guard let string = String(data: data, encoding: .utf8) else {
            throw NSError(
                domain: "IRAtomizationLLMIntegrationTests",
                code: -102,
                userInfo: [NSLocalizedDescriptionKey: "failed to encode JSON string"]
            )
        }
        return string
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
