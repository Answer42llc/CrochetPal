import Combine
import Foundation

@MainActor
final class AppContainer: ObservableObject {
    let repository: ProjectRepository
    let watchSync: WatchSyncCoordinator
    let sourceFileStore: SourceFileStoring
    private var cancellables: Set<AnyCancellable> = []

    init(
        repository: ProjectRepository,
        watchSync: WatchSyncCoordinator,
        sourceFileStore: SourceFileStoring
    ) {
        self.repository = repository
        self.watchSync = watchSync
        self.sourceFileStore = sourceFileStore
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
            let delayNanoseconds: UInt64 = ProcessInfo.processInfo.arguments.contains("-ui-testing-slow-import")
                ? 3_000_000_000
                : 0
            parserClient = FixturePatternParsingClient(
                outlineResponse: SampleDataFactory.demoOutlineResponse,
                imageResponse: SampleDataFactory.demoImageParseResponse,
                irResponse: SampleDataFactory.demoIRAtomizationResponse,
                delayNanoseconds: delayNanoseconds
            )
        } else if let configuration = try? RuntimeConfiguration.load() {
            parserClient = OpenAICompatibleLLMClient(
                configuration: configuration,
                logger: logger
            )
        } else {
            parserClient = FailingPatternClient()
        }

        let pdfExtractor = PDFExtractionService()
        let sourceFileStore = makeSourceFileStore(isUITesting: isUITesting)
        let importer = PatternImportService(
            parserClient: parserClient,
            extractor: extractor,
            pdfExtractor: pdfExtractor,
            session: makeURLSession(isUITesting: isUITesting),
            sourceFileStore: sourceFileStore,
            logger: logger
        )
        let repository = ProjectRepository(
            importer: importer,
            storage: makeStorage(isUITesting: isUITesting),
            logger: logger,
            sourceFileStore: sourceFileStore,
            backgroundTaskRunner: isUITesting ? NoopBackgroundTaskRunner() : ApplicationBackgroundTaskRunner(),
            importNotificationScheduler: isUITesting ? NoopImportNotificationScheduler() : LocalImportNotificationScheduler()
        )
        let watchSync = WatchSyncCoordinator()
        return AppContainer(
            repository: repository,
            watchSync: watchSync,
            sourceFileStore: sourceFileStore
        )
    }

    private static func makeSourceFileStore(isUITesting: Bool) -> SourceFileStoring {
        guard isUITesting else {
            return SourceFileStore()
        }

        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CrochetPal-UITests-Sources", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return SourceFileStore(baseDirectoryURL: directoryURL)
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
        abbreviations: [],
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

    private static func demoStitchAction(_ tag: String, instruction: String, produced: Int) -> ParsedAtomicAction {
        ParsedAtomicAction(
            semantics: .stitchProducing,
            actionTag: tag,
            stitchTag: tag,
            instruction: instruction,
            producedStitches: produced
        )
    }

    static let demoImageParseResponse = PatternParseResponse(
        projectTitle: "Mouse Cat Toy",
        materials: ["4.0 mm hook", "Cotton yarn", "Safety eyes"],
        confidence: 0.92,
        abbreviations: [],
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
                            demoStitchAction("mr", instruction: "mr", produced: 0),
                            demoStitchAction("sc", instruction: "sc", produced: 1),
                            demoStitchAction("sc", instruction: "sc", produced: 1),
                            demoStitchAction("sc", instruction: "sc", produced: 1),
                            demoStitchAction("sc", instruction: "sc", produced: 1),
                            demoStitchAction("sc", instruction: "sc", produced: 1),
                            demoStitchAction("sc", instruction: "sc", produced: 1)
                        ]
                    ),
                    ParsedPatternRound(
                        title: "Round 2",
                        rawInstruction: "(sc 2, inc) x 3. (12)",
                        summary: "Single crochet twice, then increase. Repeat three times.",
                        targetStitchCount: 12,
                        atomicActions: [
                            demoStitchAction("sc", instruction: "sc", produced: 1),
                            demoStitchAction("sc", instruction: "sc", produced: 1),
                            demoStitchAction("sc", instruction: "inc", produced: 1),
                            demoStitchAction("sc", instruction: "inc", produced: 1),
                            demoStitchAction("sc", instruction: "sc", produced: 1),
                            demoStitchAction("sc", instruction: "sc", produced: 1),
                            demoStitchAction("sc", instruction: "inc", produced: 1),
                            demoStitchAction("sc", instruction: "inc", produced: 1),
                            demoStitchAction("sc", instruction: "sc", produced: 1),
                            demoStitchAction("sc", instruction: "sc", produced: 1),
                            demoStitchAction("sc", instruction: "inc", produced: 1),
                            demoStitchAction("sc", instruction: "inc", produced: 1)
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
                            demoStitchAction("mr", instruction: "mr", produced: 0),
                            demoStitchAction("sc", instruction: "sc", produced: 1),
                            demoStitchAction("sc", instruction: "sc", produced: 1),
                            demoStitchAction("sc", instruction: "sc", produced: 1),
                            demoStitchAction("sc", instruction: "sc", produced: 1),
                            demoStitchAction("sc", instruction: "sc", produced: 1),
                            demoStitchAction("sc", instruction: "sc", produced: 1)
                        ]
                    )
                ]
            )
        ]
    )

    static let demoIRAtomizationResponse = CrochetIRAtomizationResponse(
        rounds: [
            CrochetIRInstructionBlock(
                title: "Round 1",
                sourceText: "In a MR, sc 6. (6)",
                expectedProducedStitches: 6,
                body: CrochetIRBlock(statements: [
                    CrochetIRStatement(
                        kind: .operation(CrochetIROperation(
                            semantics: .stitchProducing,
                            actionTag: "mr",
                            stitch: "mr",
                            count: 1
                        )),
                        sourceText: "In a MR"
                    ),
                    CrochetIRStatement(
                        kind: .operation(CrochetIROperation(
                            semantics: .stitchProducing,
                            actionTag: "sc",
                            stitch: "sc",
                            count: 6
                        )),
                        sourceText: "sc 6"
                    )
                ])
            ),
            CrochetIRInstructionBlock(
                title: "Round 2",
                sourceText: "(sc 2, inc) x 3. (12)",
                expectedProducedStitches: 12,
                body: CrochetIRBlock(statements: [
                    CrochetIRStatement(
                        kind: .repeatBlock(CrochetIRRepeatBlock(
                            times: 3,
                            body: CrochetIRBlock(statements: [
                                CrochetIRStatement(
                                    kind: .operation(CrochetIROperation(
                                        semantics: .stitchProducing,
                                        actionTag: "sc",
                                        stitch: "sc",
                                        count: 2
                                    )),
                                    sourceText: "sc 2"
                                ),
                                CrochetIRStatement(
                                    kind: .operation(CrochetIROperation(
                                        semantics: .increase,
                                        actionTag: "increase",
                                        stitch: "sc",
                                        count: 1,
                                        note: "inc",
                                        notePlacement: .all,
                                        producedStitches: 2
                                    )),
                                    sourceText: "inc"
                                )
                            ])
                        )),
                        sourceText: "(sc 2, inc) x 3"
                    )
                ])
            ),
            CrochetIRInstructionBlock(
                title: "Eye Round 1",
                sourceText: "In a MR, sc 6. (6)",
                expectedProducedStitches: 6,
                body: CrochetIRBlock(statements: [
                    CrochetIRStatement(
                        kind: .operation(CrochetIROperation(
                            semantics: .stitchProducing,
                            actionTag: "mr",
                            stitch: "mr",
                            count: 1
                        )),
                        sourceText: "In a MR"
                    ),
                    CrochetIRStatement(
                        kind: .operation(CrochetIROperation(
                            semantics: .stitchProducing,
                            actionTag: "sc",
                            stitch: "sc",
                            count: 6
                        )),
                        sourceText: "sc 6"
                    )
                ])
            )
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

    func parseTextRoundsToIR(
        projectTitle: String,
        materials: [String],
        rounds: [AtomizationRoundInput],
        context: ParseRequestContext
    ) async throws -> CrochetIRAtomizationResponse {
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
