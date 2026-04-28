import Foundation

struct LogEvent: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var timestamp: Date
    var level: String
    var traceID: String
    var parseRequestID: String?
    var projectID: UUID?
    var sourceType: PatternSourceType?
    var stage: String
    var decision: String
    var reason: String
    var durationMS: Int?
    var metadata: [String: String]
}

protocol TraceLogging {
    func log(_ event: LogEvent)
}

struct SilentTraceLogger: TraceLogging {
    func log(_ event: LogEvent) {}
}

private struct FixtureManifest: Codable {
    var fixtures: [FixtureManifestEntry]
}

private struct FixtureManifestEntry: Codable, Hashable {
    var name: String
    var title: String
    var sourceType: String
    var sourceFiles: [String]?
    var sourceURL: String?
}

private struct FixtureInput: Codable, Hashable {
    var name: String
    var title: String
    var sourceType: String
    var sourceURL: String?
    var extractedTextPath: String
    var titleHint: String?
    var baselineOutlinePath: String?
    var baselineRoundCount: Int?
}

private struct OutlineRunRecord: Codable, Hashable {
    var model: String
    var fixtureName: String
    var status: String
    var durationMS: Int?
    var responseBytes: Int?
    var rawPath: String?
    var outlinePath: String?
    var projectTitle: String?
    var partCount: Int?
    var roundCount: Int?
    var sampledRoundIndices: [Int]
    var error: String?
}

private struct AtomizationRunRecord: Codable, Hashable {
    var model: String
    var fixtureName: String
    var sampleOrdinal: Int
    var roundIndex: Int
    var roundTitle: String
    var rawInstruction: String
    var status: String
    var durationMS: Int?
    var responseBytes: Int?
    var rawPath: String?
    var irPath: String?
    var snapshotPath: String?
    var validationIssues: [CrochetIRValidationIssue]
    var expansionFailure: String?
    var producedStitchCount: Int?
    var warningCount: Int?
    var actionCount: Int?
    var error: String?
}

private struct AtomicRoundSnapshot: Codable, Hashable {
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
    var sourceText: String?
    var sequenceIndex: Int
}

private struct RunIndex: Codable, Hashable {
    var generatedAt: String
    var repoRoot: String
    var fixtureRoot: String
    var outputRoot: String
    var models: [String]
    var sampleCount: Int
    var fixtures: [FixtureInput]
    var outlineResults: [OutlineRunRecord]
    var atomizationResults: [AtomizationRunRecord]
}

private struct ChatResult {
    var content: String
    var durationMS: Int
    var responseBytes: Int
}

private struct HTTPFailure: Error, CustomStringConvertible {
    var statusCode: Int
    var bodyPreview: String

    var description: String {
        "HTTP \(statusCode): \(bodyPreview)"
    }
}

private struct RequestTimeoutFailure: Error, CustomStringConvertible {
    var modelID: String
    var timeoutSeconds: TimeInterval

    var description: String {
        "request timed out for \(modelID) after \(Int(timeoutSeconds))s"
    }
}

@main
private struct LLMModelComparisonRunner {
    private let defaultModels = [
        "qwen/qwen3.6-plus",
        "deepseek/deepseek-v4-flash",
        "deepseek/deepseek-v4-pro"
    ]

    static func main() async {
        do {
            try await LLMModelComparisonRunner().run()
        } catch {
            fputs("error: \(error)\n", stderr)
            exit(1)
        }
    }

    private func run() async throws {
        let arguments = CommandLine.arguments.dropFirst()
        let options = try parseOptions(Array(arguments))
        let repoRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let fixtureRoot = repoRoot.appendingPathComponent("CrochetPalTests/Fixtures/LLM")
        let outputRoot = try makeOutputRoot(repoRoot: repoRoot, requestedPath: options.outputRoot)
        let configuration = try loadConfiguration(repoRoot: repoRoot)
        let models = options.models.isEmpty ? defaultModels : options.models
        let fixtures = try loadFixtureInputs(
            fixtureRoot: fixtureRoot,
            selectedFixtureNames: options.fixtureNames
        )

        print("[llm-model-comparison] output=\(outputRoot.path)")
        print("[llm-model-comparison] models=\(models.joined(separator: ", "))")
        print("[llm-model-comparison] fixtures=\(fixtures.map(\.name).joined(separator: ", "))")

        let outlineJobs = models.flatMap { model in
            fixtures.map { fixture in (model: model, fixture: fixture) }
        }

        let outlineResults = await runInBatches(
            outlineJobs,
            concurrency: options.concurrency
        ) { job in
            await runOutlineJob(
                model: job.model,
                fixture: job.fixture,
                configuration: configuration,
                outputRoot: outputRoot,
                sampleCount: options.sampleCount,
                requestTimeoutSeconds: options.requestTimeoutSeconds
            )
        }

        let atomizationJobs = try outlineResults.flatMap { record -> [(model: String, fixture: FixtureInput, outline: PatternOutlineResponse, roundIndex: Int, sampleOrdinal: Int)] in
            guard record.status == "success",
                  let outlinePath = record.outlinePath else {
                return []
            }
            let outline = try JSONDecoder().decode(
                PatternOutlineResponse.self,
                from: Data(contentsOf: URL(fileURLWithPath: outlinePath))
            )
            let fixture = fixtures.first { $0.name == record.fixtureName }!
            return record.sampledRoundIndices.enumerated().map { offset, roundIndex in
                (record.model, fixture, outline, roundIndex, offset + 1)
            }
        }

        let atomizationResults = await runInBatches(
            atomizationJobs,
            concurrency: options.concurrency
        ) { job in
            await runAtomizationJob(
                model: job.model,
                fixture: job.fixture,
                outline: job.outline,
                roundIndex: job.roundIndex,
                sampleOrdinal: job.sampleOrdinal,
                configuration: configuration,
                outputRoot: outputRoot,
                requestTimeoutSeconds: options.atomizationTimeoutSeconds ?? options.requestTimeoutSeconds
            )
        }

        let index = RunIndex(
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            repoRoot: repoRoot.path,
            fixtureRoot: fixtureRoot.path,
            outputRoot: outputRoot.path,
            models: models,
            sampleCount: options.sampleCount,
            fixtures: fixtures,
            outlineResults: outlineResults.sorted { ($0.model, $0.fixtureName) < ($1.model, $1.fixtureName) },
            atomizationResults: atomizationResults.sorted {
                ($0.model, $0.fixtureName, $0.roundIndex) < ($1.model, $1.fixtureName, $1.roundIndex)
            }
        )
        try writePrettyJSON(index, to: outputRoot.appendingPathComponent("run_index.json"))
        try writeMarkdownSummary(index, to: outputRoot.appendingPathComponent("SUMMARY.md"))

        let outlineSuccess = outlineResults.filter { $0.status == "success" }.count
        let atomizationSuccess = atomizationResults.filter { $0.status == "success" }.count
        print("[llm-model-comparison] outline success \(outlineSuccess)/\(outlineResults.count)")
        print("[llm-model-comparison] atomization success \(atomizationSuccess)/\(atomizationResults.count)")
        print("[llm-model-comparison] wrote \(outputRoot.appendingPathComponent("run_index.json").path)")
    }

    private struct Options {
        var outputRoot: String?
        var models: [String] = []
        var fixtureNames: Set<String>?
        var sampleCount = 5
        var concurrency = 3
        var requestTimeoutSeconds: TimeInterval = 480
        var atomizationTimeoutSeconds: TimeInterval?
    }

    private func parseOptions(_ args: [String]) throws -> Options {
        var options = Options()
        var index = 0
        while index < args.count {
            let arg = args[index]
            func requireValue() throws -> String {
                let valueIndex = index + 1
                guard valueIndex < args.count else {
                    throw NSError(domain: "LLMModelComparisonRunner", code: -1, userInfo: [
                        NSLocalizedDescriptionKey: "\(arg) requires a value"
                    ])
                }
                index += 1
                return args[valueIndex]
            }

            switch arg {
            case "--output-root":
                options.outputRoot = try requireValue()
            case "--models":
                options.models = try requireValue().split(separator: ",").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            case "--fixtures":
                let names = try requireValue().split(separator: ",").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                options.fixtureNames = Set(names)
            case "--sample-count":
                options.sampleCount = max(1, Int(try requireValue()) ?? 5)
            case "--concurrency":
                options.concurrency = max(1, Int(try requireValue()) ?? 3)
            case "--request-timeout-seconds":
                options.requestTimeoutSeconds = max(1, TimeInterval(Int(try requireValue()) ?? 480))
            case "--atomization-timeout-seconds":
                options.atomizationTimeoutSeconds = max(1, TimeInterval(Int(try requireValue()) ?? 120))
            default:
                throw NSError(domain: "LLMModelComparisonRunner", code: -2, userInfo: [
                    NSLocalizedDescriptionKey: "unknown argument \(arg)"
                ])
            }
            index += 1
        }
        return options
    }

    private func makeOutputRoot(repoRoot: URL, requestedPath: String?) throws -> URL {
        let outputRoot: URL
        if let requestedPath, !requestedPath.isEmpty {
            outputRoot = requestedPath.hasPrefix("/")
                ? URL(fileURLWithPath: requestedPath)
                : repoRoot.appendingPathComponent(requestedPath)
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            outputRoot = repoRoot
                .appendingPathComponent("LLMModelComparisonResults")
                .appendingPathComponent("run-\(formatter.string(from: Date()))")
        }
        try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)
        return outputRoot
    }

    private func loadConfiguration(repoRoot: URL) throws -> RuntimeConfiguration {
        let secretsURL = repoRoot.appendingPathComponent("Config/Secrets.xcconfig")
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

        let env = ProcessInfo.processInfo.environment
        return try RuntimeConfiguration.load(values: [
            "OPENAI_API_KEY": resolve(raw["OPENAI_API_KEY"] ?? "").ifEmpty(env["OPENAI_API_KEY"]),
            "OPENAI_BASE_URL": resolve(raw["OPENAI_BASE_URL"] ?? "").ifEmpty(env["OPENAI_BASE_URL"]),
            "TEXT_MODEL_ID": resolve(raw["TEXT_MODEL_ID"] ?? ""),
            "ATOMIZATION_MODEL_ID": resolve(raw["ATOMIZATION_MODEL_ID"] ?? raw["TEXT_MODEL_ID"] ?? ""),
            "VISION_MODEL_ID": resolve(raw["VISION_MODEL_ID"] ?? raw["TEXT_MODEL_ID"] ?? "")
        ])
    }

    private func loadFixtureInputs(
        fixtureRoot: URL,
        selectedFixtureNames: Set<String>?
    ) throws -> [FixtureInput] {
        let manifestURL = fixtureRoot.appendingPathComponent("fixture_manifest.json")
        let manifest = try JSONDecoder().decode(FixtureManifest.self, from: Data(contentsOf: manifestURL))

        return try manifest.fixtures.compactMap { entry in
            if let selectedFixtureNames, !selectedFixtureNames.contains(entry.name) {
                return nil
            }

            let dir = fixtureRoot.appendingPathComponent(entry.name)
            let extractedURL = dir.appendingPathComponent("extracted_text.txt")
            let rawTextURL = dir.appendingPathComponent("raw.txt")
            let rawHTMLURL = dir.appendingPathComponent("raw.html")
            let sourceURL: URL
            if FileManager.default.fileExists(atPath: extractedURL.path) {
                sourceURL = extractedURL
            } else if FileManager.default.fileExists(atPath: rawTextURL.path) {
                sourceURL = rawTextURL
            } else if FileManager.default.fileExists(atPath: rawHTMLURL.path) {
                sourceURL = rawHTMLURL
            } else {
                throw NSError(domain: "LLMModelComparisonRunner", code: -10, userInfo: [
                    NSLocalizedDescriptionKey: "\(entry.name) has no extracted_text.txt/raw.txt/raw.html"
                ])
            }

            let baselineOutlineURL = dir.appendingPathComponent("outline.json")
            let baselineRoundCount: Int? = try? JSONDecoder()
                .decode(PatternOutlineResponse.self, from: Data(contentsOf: baselineOutlineURL))
                .parts
                .flatMap(\.rounds)
                .count

            return FixtureInput(
                name: entry.name,
                title: entry.title,
                sourceType: entry.sourceType,
                sourceURL: entry.sourceURL,
                extractedTextPath: sourceURL.path,
                titleHint: entry.title,
                baselineOutlinePath: FileManager.default.fileExists(atPath: baselineOutlineURL.path) ? baselineOutlineURL.path : nil,
                baselineRoundCount: baselineRoundCount
            )
        }
    }

    private func runInBatches<Input, Output>(
        _ inputs: [Input],
        concurrency: Int,
        operation: @escaping (Input) async -> Output
    ) async -> [Output] {
        var outputs = Array<Output?>(repeating: nil, count: inputs.count)
        for batchStart in stride(from: 0, to: inputs.count, by: concurrency) {
            let batchEnd = min(batchStart + concurrency, inputs.count)
            await withTaskGroup(of: (Int, Output).self) { group in
                for index in batchStart..<batchEnd {
                    group.addTask {
                        (index, await operation(inputs[index]))
                    }
                }
                for await (index, output) in group {
                    outputs[index] = output
                }
            }
        }
        return outputs.compactMap { $0 }
    }

    private func runOutlineJob(
        model: String,
        fixture: FixtureInput,
        configuration: RuntimeConfiguration,
        outputRoot: URL,
        sampleCount: Int,
        requestTimeoutSeconds: TimeInterval
    ) async -> OutlineRunRecord {
        let modelDir = outputRoot.appendingPathComponent(safePathComponent(model))
        let fixtureDir = modelDir.appendingPathComponent(fixture.name)
        let rawPath = fixtureDir.appendingPathComponent("outline_raw.json")
        let outlinePath = fixtureDir.appendingPathComponent("outline.json")

        do {
            try FileManager.default.createDirectory(at: fixtureDir, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: outlinePath.path) {
                let outline = try JSONDecoder().decode(
                    PatternOutlineResponse.self,
                    from: Data(contentsOf: outlinePath)
                )
                let flatRounds = outline.parts.flatMap(\.rounds)
                let sampledRoundIndices = sampleIndices(total: flatRounds.count, sampleCount: sampleCount)
                print("[outline] \(model) \(fixture.name): reused rounds=\(flatRounds.count)")
                return OutlineRunRecord(
                    model: model,
                    fixtureName: fixture.name,
                    status: "success",
                    durationMS: nil,
                    responseBytes: nil,
                    rawPath: FileManager.default.fileExists(atPath: rawPath.path) ? rawPath.path : nil,
                    outlinePath: outlinePath.path,
                    projectTitle: outline.projectTitle,
                    partCount: outline.parts.count,
                    roundCount: flatRounds.count,
                    sampledRoundIndices: sampledRoundIndices,
                    error: nil
                )
            }

            let extractedText = try String(contentsOfFile: fixture.extractedTextPath, encoding: .utf8)
            let chat = try await fetchAssistantContent(
                configuration: configuration,
                modelID: model,
                systemPrompt: PromptFactory.textOutlineSystemPrompt(),
                userPrompt: PromptFactory.textOutlinePrompt(extractedText: extractedText, titleHint: fixture.titleHint),
                responseFormat: PromptFactory.outlineResponseFormat(),
                timeoutSeconds: requestTimeoutSeconds
            )
            try chat.content.write(to: rawPath, atomically: true, encoding: .utf8)
            let outline = try decodeJSON(PatternOutlineResponse.self, from: chat.content)
            try writePrettyJSON(outline, to: outlinePath)
            let flatRounds = outline.parts.flatMap(\.rounds)
            let sampledRoundIndices = sampleIndices(total: flatRounds.count, sampleCount: sampleCount)
            print("[outline] \(model) \(fixture.name): success rounds=\(flatRounds.count)")
            return OutlineRunRecord(
                model: model,
                fixtureName: fixture.name,
                status: "success",
                durationMS: chat.durationMS,
                responseBytes: chat.responseBytes,
                rawPath: rawPath.path,
                outlinePath: outlinePath.path,
                projectTitle: outline.projectTitle,
                partCount: outline.parts.count,
                roundCount: flatRounds.count,
                sampledRoundIndices: sampledRoundIndices,
                error: nil
            )
        } catch {
            let message = String(describing: error)
            try? message.write(to: fixtureDir.appendingPathComponent("outline.error.txt"), atomically: true, encoding: .utf8)
            print("[outline] \(model) \(fixture.name): failed \(message)")
            return OutlineRunRecord(
                model: model,
                fixtureName: fixture.name,
                status: "failed",
                durationMS: nil,
                responseBytes: nil,
                rawPath: FileManager.default.fileExists(atPath: rawPath.path) ? rawPath.path : nil,
                outlinePath: nil,
                projectTitle: nil,
                partCount: nil,
                roundCount: nil,
                sampledRoundIndices: [],
                error: message
            )
        }
    }

    private func runAtomizationJob(
        model: String,
        fixture: FixtureInput,
        outline: PatternOutlineResponse,
        roundIndex: Int,
        sampleOrdinal: Int,
        configuration: RuntimeConfiguration,
        outputRoot: URL,
        requestTimeoutSeconds: TimeInterval
    ) async -> AtomizationRunRecord {
        let flatRounds = outline.parts.flatMap { part in
            part.rounds.map { (partName: part.name, round: $0) }
        }
        let pair = flatRounds[roundIndex]
        let round = pair.round
        let safeTitle = safePathComponent("\(sampleOrdinal)-\(round.title)")
        let caseDir = outputRoot
            .appendingPathComponent(safePathComponent(model))
            .appendingPathComponent(fixture.name)
            .appendingPathComponent("atomization")
            .appendingPathComponent(safeTitle)
        let rawPath = caseDir.appendingPathComponent("ir_raw.json")
        let irPath = caseDir.appendingPathComponent("ir_atomization.json")
        let snapshotPath = caseDir.appendingPathComponent("atomic_snapshot.json")

        let input = AtomizationRoundInput(
            partName: pair.partName,
            title: round.title,
            rawInstruction: round.rawInstruction,
            summary: round.summary,
            targetStitchCount: round.targetStitchCount,
            previousRoundStitchCount: nil,
            abbreviations: outline.abbreviations
        )

        do {
            try FileManager.default.createDirectory(at: caseDir, withIntermediateDirectories: true)
            try writePrettyJSON(input, to: caseDir.appendingPathComponent("atomization_input.json"))
            if FileManager.default.fileExists(atPath: snapshotPath.path),
               FileManager.default.fileExists(atPath: irPath.path) {
                let snapshot = try JSONDecoder().decode(
                    AtomicRoundSnapshot.self,
                    from: Data(contentsOf: snapshotPath)
                )
                print("[atomization] \(model) \(fixture.name) \(sampleOrdinal)/\(round.title): reused actions=\(snapshot.actions.count)")
                return AtomizationRunRecord(
                    model: model,
                    fixtureName: fixture.name,
                    sampleOrdinal: sampleOrdinal,
                    roundIndex: roundIndex,
                    roundTitle: round.title,
                    rawInstruction: round.rawInstruction,
                    status: "success",
                    durationMS: nil,
                    responseBytes: nil,
                    rawPath: FileManager.default.fileExists(atPath: rawPath.path) ? rawPath.path : nil,
                    irPath: irPath.path,
                    snapshotPath: snapshotPath.path,
                    validationIssues: snapshot.validationIssues,
                    expansionFailure: snapshot.expansionFailure,
                    producedStitchCount: snapshot.producedStitchCount,
                    warningCount: snapshot.warnings.count,
                    actionCount: snapshot.actions.count,
                    error: nil
                )
            }

            let chat = try await fetchAssistantContent(
                configuration: configuration,
                modelID: model,
                systemPrompt: PromptFactory.roundIRAtomizationSystemPrompt(),
                userPrompt: PromptFactory.roundIRAtomizationPrompt(
                    projectTitle: outline.projectTitle,
                    materials: outline.materials,
                    rounds: [input]
                ),
                responseFormat: PromptFactory.irAtomizationResponseFormat(),
                timeoutSeconds: requestTimeoutSeconds
            )
            try chat.content.write(to: rawPath, atomically: true, encoding: .utf8)
            let ir = try decodeJSON(CrochetIRAtomizationResponse.self, from: chat.content)
            try writePrettyJSON(ir, to: irPath)

            guard let block = ir.rounds.first else {
                throw NSError(domain: "LLMModelComparisonRunner", code: -30, userInfo: [
                    NSLocalizedDescriptionKey: "atomization returned zero rounds"
                ])
            }
            let snapshot = buildAtomicSnapshot(from: block)
            try writePrettyJSON(snapshot, to: snapshotPath)
            print("[atomization] \(model) \(fixture.name) \(sampleOrdinal)/\(round.title): success actions=\(snapshot.actions.count)")
            return AtomizationRunRecord(
                model: model,
                fixtureName: fixture.name,
                sampleOrdinal: sampleOrdinal,
                roundIndex: roundIndex,
                roundTitle: round.title,
                rawInstruction: round.rawInstruction,
                status: "success",
                durationMS: chat.durationMS,
                responseBytes: chat.responseBytes,
                rawPath: rawPath.path,
                irPath: irPath.path,
                snapshotPath: snapshotPath.path,
                validationIssues: snapshot.validationIssues,
                expansionFailure: snapshot.expansionFailure,
                producedStitchCount: snapshot.producedStitchCount,
                warningCount: snapshot.warnings.count,
                actionCount: snapshot.actions.count,
                error: nil
            )
        } catch {
            let message = String(describing: error)
            try? message.write(to: caseDir.appendingPathComponent("atomization.error.txt"), atomically: true, encoding: .utf8)
            print("[atomization] \(model) \(fixture.name) \(sampleOrdinal)/\(round.title): failed \(message)")
            return AtomizationRunRecord(
                model: model,
                fixtureName: fixture.name,
                sampleOrdinal: sampleOrdinal,
                roundIndex: roundIndex,
                roundTitle: round.title,
                rawInstruction: round.rawInstruction,
                status: "failed",
                durationMS: nil,
                responseBytes: nil,
                rawPath: FileManager.default.fileExists(atPath: rawPath.path) ? rawPath.path : nil,
                irPath: nil,
                snapshotPath: nil,
                validationIssues: [],
                expansionFailure: nil,
                producedStitchCount: nil,
                warningCount: nil,
                actionCount: nil,
                error: message
            )
        }
    }

    private func fetchAssistantContent(
        configuration: RuntimeConfiguration,
        modelID: String,
        systemPrompt: String,
        userPrompt: String,
        responseFormat: [String: Any],
        timeoutSeconds: TimeInterval
    ) async throws -> ChatResult {
        var request = URLRequest(url: configuration.baseURL.appending(path: "chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")

        var body: [String: Any] = [
            "model": modelID,
            "temperature": 0,
            "max_tokens": 32000,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt]
            ],
            "response_format": responseFormat
        ]
        if usesOpenRouterExtensions(baseURL: configuration.baseURL) {
            body["plugins"] = [["id": "response-healing"]]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let started = Date()
        let (data, response) = try await performRequest(
            request,
            modelID: modelID,
            timeoutSeconds: timeoutSeconds
        )
        let durationMS = Int(Date().timeIntervalSince(started) * 1000)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let preview = String(data: data, encoding: .utf8).map { String($0.prefix(1000)) } ?? ""
            throw HTTPFailure(statusCode: status, bodyPreview: preview)
        }
        guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = envelope["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else {
            throw NSError(domain: "LLMModelComparisonRunner", code: -40, userInfo: [
                NSLocalizedDescriptionKey: "could not parse chat completion envelope"
            ])
        }
        if let content = message["content"] as? String {
            return ChatResult(content: content, durationMS: durationMS, responseBytes: data.count)
        }
        if let parts = message["content"] as? [[String: Any]] {
            let content = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
            return ChatResult(content: content, durationMS: durationMS, responseBytes: data.count)
        }
        throw NSError(domain: "LLMModelComparisonRunner", code: -41, userInfo: [
            NSLocalizedDescriptionKey: "chat completion response did not contain message.content"
        ])
    }

    private final class URLSessionTaskState: @unchecked Sendable {
        let lock = NSLock()
        var completed = false
        var task: URLSessionDataTask?
    }

    private func performRequest(
        _ request: URLRequest,
        modelID: String,
        timeoutSeconds: TimeInterval
    ) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            let state = URLSessionTaskState()
            let task = URLSession.shared.dataTask(with: request) { data, response, error in
                state.lock.lock()
                if state.completed {
                    state.lock.unlock()
                    return
                }
                state.completed = true
                state.lock.unlock()

                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let data, let response else {
                    continuation.resume(throwing: NSError(
                        domain: "LLMModelComparisonRunner",
                        code: -42,
                        userInfo: [NSLocalizedDescriptionKey: "missing URLSession data or response"]
                    ))
                    return
                }
                continuation.resume(returning: (data, response))
            }
            state.task = task
            task.resume()

            DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds) {
                state.lock.lock()
                if state.completed {
                    state.lock.unlock()
                    return
                }
                state.completed = true
                let task = state.task
                state.lock.unlock()

                task?.cancel()
                continuation.resume(throwing: RequestTimeoutFailure(
                    modelID: modelID,
                    timeoutSeconds: timeoutSeconds
                ))
            }
        }
    }

    private func withTimeout<T>(
        seconds: TimeInterval,
        modelID: String,
        operation: @escaping () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw RequestTimeoutFailure(modelID: modelID, timeoutSeconds: seconds)
            }

            guard let result = try await group.next() else {
                throw RequestTimeoutFailure(modelID: modelID, timeoutSeconds: seconds)
            }
            group.cancelAll()
            return result
        }
    }

    private func buildAtomicSnapshot(from block: CrochetIRInstructionBlock) -> AtomicRoundSnapshot {
        let compiler = CrochetIRCompiler()
        let validationReport = compiler.validate(block)
        do {
            let expansion = try compiler.expand(block)
            return AtomicRoundSnapshot(
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
                        sourceText: action.sourceText,
                        sequenceIndex: action.sequenceIndex
                    )
                }
            )
        } catch {
            return AtomicRoundSnapshot(
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

    private func sampleIndices(total: Int, sampleCount: Int) -> [Int] {
        guard total > 0 else { return [] }
        guard sampleCount > 1 else { return [0] }
        guard total > sampleCount else { return Array(0..<total) }
        var result: [Int] = []
        for slot in 0..<sampleCount {
            let value = Double(slot) * Double(total - 1) / Double(sampleCount - 1)
            let index = Int(value.rounded())
            if !result.contains(index) {
                result.append(index)
            }
        }
        var fill = 0
        while result.count < sampleCount, fill < total {
            if !result.contains(fill) {
                result.append(fill)
            }
            fill += 1
        }
        return result.sorted()
    }

    private func decodeJSON<T: Decodable>(_ type: T.Type, from content: String) throws -> T {
        let payload = extractJSONObject(from: content)
        return try JSONDecoder().decode(T.self, from: Data(payload.utf8))
    }

    private func extractJSONObject(from text: String) -> String {
        guard let first = text.firstIndex(of: "{"), let last = text.lastIndex(of: "}") else {
            return text
        }
        return String(text[first...last])
    }

    private func safePathComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let scalars = value.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : "_"
        }
        let collapsed = String(scalars)
            .split(separator: "_", omittingEmptySubsequences: true)
            .joined(separator: "_")
        return collapsed.isEmpty ? "item" : String(collapsed.prefix(120))
    }

    private func usesOpenRouterExtensions(baseURL: URL) -> Bool {
        let host = baseURL.host?.lowercased() ?? ""
        let path = baseURL.path.lowercased()
        return host.contains("openrouter.ai") || path.contains("/openrouter/")
    }

    private func writePrettyJSON<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        try data.write(to: url)
    }

    private func writeMarkdownSummary(_ index: RunIndex, to url: URL) throws {
        var lines: [String] = []
        lines.append("# LLM Model Comparison")
        lines.append("")
        lines.append("- Generated: \(index.generatedAt)")
        lines.append("- Fixture root: \(index.fixtureRoot)")
        lines.append("- Sample count: \(index.sampleCount)")
        lines.append("")
        lines.append("## Outline")
        lines.append("")
        for model in index.models {
            let records = index.outlineResults.filter { $0.model == model }
            let success = records.filter { $0.status == "success" }.count
            lines.append("- \(model): \(success)/\(records.count) success")
        }
        lines.append("")
        lines.append("## Atomization")
        lines.append("")
        for model in index.models {
            let records = index.atomizationResults.filter { $0.model == model }
            let success = records.filter { $0.status == "success" }.count
            lines.append("- \(model): \(success)/\(records.count) success")
        }
        lines.append("")
        lines.append("Detailed machine-readable results are in `run_index.json`.")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}

private extension String {
    func ifEmpty(_ fallback: String?) -> String {
        isEmpty ? (fallback ?? "") : self
    }
}
