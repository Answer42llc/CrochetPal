import Combine
import Foundation

@MainActor
final class AppContainer: ObservableObject {
    let repository: ProjectRepository
    let watchSync: WatchSyncCoordinator
    private var cancellables: Set<AnyCancellable> = []

    init(repository: ProjectRepository, watchSync: WatchSyncCoordinator) {
        self.repository = repository
        self.watchSync = watchSync
        repository.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
        repository.attachWatchSync(watchSync)
    }

    static func make() -> AppContainer {
        let isUITesting = ProcessInfo.processInfo.arguments.contains("-ui-testing")
        let logger = ConsoleTraceLogger()
        let extractor = HTMLExtractionService()
        let parserClient: PatternLLMParsing

        if isUITesting {
            parserClient = FixturePatternParsingClient(
                outlineResponse: SampleDataFactory.demoOutlineResponse,
                imageResponse: SampleDataFactory.demoImageParseResponse,
                atomizationResponse: SampleDataFactory.demoAtomizationResponse
            )
        } else if let configuration = try? RuntimeConfiguration.load() {
            parserClient = OpenAICompatibleLLMClient(configuration: configuration, logger: logger)
        } else {
            parserClient = FailingPatternClient()
        }

        let pdfExtractor = PDFExtractionService()
        let importer = PatternImportService(
            parserClient: parserClient,
            extractor: extractor,
            pdfExtractor: pdfExtractor,
            session: makeURLSession(isUITesting: isUITesting),
            logger: logger
        )
        let repository = ProjectRepository(
            importer: importer,
            storage: makeStorage(isUITesting: isUITesting),
            logger: logger
        )
        let watchSync = WatchSyncCoordinator()
        return AppContainer(repository: repository, watchSync: watchSync)
    }

    private static func makeStorage(isUITesting: Bool) -> JSONFileStore {
        guard isUITesting else {
            return JSONFileStore()
        }

        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CrochetPal-UITests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        return JSONFileStore(directoryURL: directoryURL)
    }

    private static func makeURLSession(isUITesting: Bool) -> URLSession {
        guard isUITesting else {
            return .shared
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UITestURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

struct SampleDataFactory {
    static let sampleHTML = """
    <html>
    <head><title>Mouse Cat Toy Crochet Pattern</title></head>
    <body>
    <article>
    <h1>Mouse Cat Toy</h1>
    <p>Materials</p>
    <p>4.0 mm hook, cotton yarn, safety eyes</p>
    <p>Body</p>
    <p>Round 1: In a MR, sc 6. (6)</p>
    <p>Round 2: (sc 2, inc) x 3. (12)</p>
    </article>
    </body>
    </html>
    """

    static let demoOutlineResponse = PatternOutlineResponse(
        projectTitle: "Mouse Cat Toy",
        materials: ["4.0 mm hook", "Cotton yarn", "Safety eyes"],
        confidence: 0.92,
        parts: [
            OutlinedPatternPart(
                name: "Body",
                rounds: [
                    OutlinedPatternRound(
                        title: "Round 1",
                        rawInstruction: "In a MR, sc 6. (6)",
                        summary: "Create a magic ring and crochet six single crochets into it.",
                        targetStitchCount: 6
                    ),
                    OutlinedPatternRound(
                        title: "Round 2",
                        rawInstruction: "(sc 2, inc) x 3. (12)",
                        summary: "Single crochet twice, then increase. Repeat three times.",
                        targetStitchCount: 12
                    )
                ]
            ),
            OutlinedPatternPart(
                name: "Eyes",
                rounds: [
                    OutlinedPatternRound(
                        title: "Eye Round 1",
                        rawInstruction: "In a MR, sc 6. (6)",
                        summary: "Make the eye base.",
                        targetStitchCount: 6
                    )
                ]
            )
        ]
    )

    static let demoImageParseResponse = PatternParseResponse(
        projectTitle: "Mouse Cat Toy",
        materials: ["4.0 mm hook", "Cotton yarn", "Safety eyes"],
        confidence: 0.92,
        parts: [
            ParsedPatternPart(
                name: "Body",
                rounds: [
                    ParsedPatternRound(
                        title: "Round 1",
                        rawInstruction: "In a MR, sc 6. (6)",
                        summary: "Create a magic ring and crochet six single crochets into it.",
                        targetStitchCount: 6,
                        atomicActions: [
                            ParsedAtomicAction(type: .mr, instruction: "mr", producedStitches: 0),
                            ParsedAtomicAction(type: .sc, instruction: "sc", producedStitches: 1),
                            ParsedAtomicAction(type: .sc, instruction: "sc", producedStitches: 1),
                            ParsedAtomicAction(type: .sc, instruction: "sc", producedStitches: 1),
                            ParsedAtomicAction(type: .sc, instruction: "sc", producedStitches: 1),
                            ParsedAtomicAction(type: .sc, instruction: "sc", producedStitches: 1),
                            ParsedAtomicAction(type: .sc, instruction: "sc", producedStitches: 1)
                        ]
                    ),
                    ParsedPatternRound(
                        title: "Round 2",
                        rawInstruction: "(sc 2, inc) x 3. (12)",
                        summary: "Single crochet twice, then increase. Repeat three times.",
                        targetStitchCount: 12,
                        atomicActions: [
                            ParsedAtomicAction(type: .sc, instruction: "sc", producedStitches: 1),
                            ParsedAtomicAction(type: .sc, instruction: "sc", producedStitches: 1),
                            ParsedAtomicAction(type: .inc, instruction: "inc", producedStitches: 2),
                            ParsedAtomicAction(type: .sc, instruction: "sc", producedStitches: 1),
                            ParsedAtomicAction(type: .sc, instruction: "sc", producedStitches: 1),
                            ParsedAtomicAction(type: .inc, instruction: "inc", producedStitches: 2),
                            ParsedAtomicAction(type: .sc, instruction: "sc", producedStitches: 1),
                            ParsedAtomicAction(type: .sc, instruction: "sc", producedStitches: 1),
                            ParsedAtomicAction(type: .inc, instruction: "inc", producedStitches: 2)
                        ]
                    )
                ]
            ),
            ParsedPatternPart(
                name: "Eyes",
                rounds: [
                    ParsedPatternRound(
                        title: "Eye Round 1",
                        rawInstruction: "In a MR, sc 6. (6)",
                        summary: "Make the eye base.",
                        targetStitchCount: 6,
                        atomicActions: [
                            ParsedAtomicAction(type: .mr, instruction: "mr", producedStitches: 0),
                            ParsedAtomicAction(type: .sc, instruction: "sc", producedStitches: 1),
                            ParsedAtomicAction(type: .sc, instruction: "sc", producedStitches: 1),
                            ParsedAtomicAction(type: .sc, instruction: "sc", producedStitches: 1),
                            ParsedAtomicAction(type: .sc, instruction: "sc", producedStitches: 1),
                            ParsedAtomicAction(type: .sc, instruction: "sc", producedStitches: 1),
                            ParsedAtomicAction(type: .sc, instruction: "sc", producedStitches: 1)
                        ]
                    )
                ]
            )
        ]
    )

    static let demoAtomizationResponse = RoundAtomizationResponse(
        rounds: [
            AtomizedPatternRound(segments: [
                .stitchRun(
                    StitchRunSegment(
                        type: .mr,
                        count: 1,
                        instruction: nil,
                        producedStitches: nil,
                        note: nil,
                        notePlacement: .first,
                        verbatim: "In a MR"
                    )
                ),
                .stitchRun(
                    StitchRunSegment(
                        type: .sc,
                        count: 6,
                        instruction: nil,
                        producedStitches: nil,
                        note: nil,
                        notePlacement: .first,
                        verbatim: "sc 6"
                    )
                )
            ]),
            AtomizedPatternRound(segments: [
                .repeatBlock(
                    RepeatSegment(
                        times: 3,
                        sequence: [
                            .stitchRun(
                                StitchRunSegment(
                                    type: .sc,
                                    count: 2,
                                    instruction: nil,
                                    producedStitches: nil,
                                    note: nil,
                                    notePlacement: .first,
                                    verbatim: "sc 2"
                                )
                            ),
                            .stitchRun(
                                StitchRunSegment(
                                    type: .inc,
                                    count: 1,
                                    instruction: nil,
                                    producedStitches: nil,
                                    note: nil,
                                    notePlacement: .first,
                                    verbatim: "inc"
                                )
                            )
                        ],
                        verbatim: "(sc 2, inc) x 3"
                    )
                )
            ]),
            AtomizedPatternRound(segments: [
                .stitchRun(
                    StitchRunSegment(
                        type: .mr,
                        count: 1,
                        instruction: nil,
                        producedStitches: nil,
                        note: nil,
                        notePlacement: .first,
                        verbatim: "In a MR"
                    )
                ),
                .stitchRun(
                    StitchRunSegment(
                        type: .sc,
                        count: 6,
                        instruction: nil,
                        producedStitches: nil,
                        note: nil,
                        notePlacement: .first,
                        verbatim: "sc 6"
                    )
                )
            ])
        ]
    )

    static let sampleImageData = Data([0x89, 0x50, 0x4e, 0x47])
}

final class FailingPatternClient: PatternLLMParsing {
    func parseTextPatternOutline(
        extractedText: String,
        titleHint: String?,
        context: ParseRequestContext
    ) async throws -> PatternOutlineResponse {
        throw PatternImportFailure.missingConfiguration("OPENAI_API_KEY")
    }

    func atomizeTextRounds(
        projectTitle: String,
        materials: [String],
        rounds: [AtomizationRoundInput],
        context: ParseRequestContext
    ) async throws -> RoundAtomizationResponse {
        throw PatternImportFailure.missingConfiguration("OPENAI_API_KEY")
    }

    func parseImagePattern(
        imageData: Data,
        mimeType: String,
        fileName: String,
        context: ParseRequestContext
    ) async throws -> PatternParseResponse {
        throw PatternImportFailure.missingConfiguration("OPENAI_API_KEY")
    }
}

private final class UITestURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "text/html; charset=utf-8"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(SampleDataFactory.sampleHTML.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
