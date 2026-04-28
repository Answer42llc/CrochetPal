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
}

private struct OutlineRunRecord: Codable, Hashable {
    var model: String
    var requestModel: String
    var fixtureName: String
    var status: String
    var durationMS: Int?
    var responseBytes: Int?
    var envelopePath: String?
    var argumentsPath: String?
    var outlinePath: String?
    var roundCount: Int?
    var sampledRoundIndices: [Int]
    var error: String?
}

private struct AtomizationRunRecord: Codable, Hashable {
    var model: String
    var requestModel: String
    var fixtureName: String
    var sampleOrdinal: Int
    var roundIndex: Int
    var roundTitle: String
    var rawInstruction: String
    var status: String
    var durationMS: Int?
    var responseBytes: Int?
    var envelopePath: String?
    var argumentsPath: String?
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
    var baseURL: String
    var outputRoot: String
    var models: [String]
    var sampleCount: Int
    var fixtures: [FixtureInput]
    var outlineResults: [OutlineRunRecord]
    var atomizationResults: [AtomizationRunRecord]
}

private struct ToolCallResult {
    var arguments: String
    var envelope: String
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

private struct MissingConfiguration: Error, CustomStringConvertible {
    var key: String

    var description: String {
        "缺少配置项：\(key)。请设置环境变量或 Config/Secrets.xcconfig。"
    }
}

@main
private struct DeepSeekStrictToolComparisonRunner {
    private let defaultModels = [
        "deepseek/deepseek-v4-flash",
        "deepseek/deepseek-v4-pro"
    ]

    static func main() async {
        do {
            try await DeepSeekStrictToolComparisonRunner().run()
        } catch {
            fputs("error: \(error)\n", stderr)
            exit(1)
        }
    }

    private func run() async throws {
        let options = try parseOptions(Array(CommandLine.arguments.dropFirst()))
        let repoRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let fixtureRoot = repoRoot.appendingPathComponent("CrochetPalTests/Fixtures/LLM")
        let outputRoot = try makeOutputRoot(repoRoot: repoRoot, requestedPath: options.outputRoot)

        let outlineSchema = try strictToolSchema(from: PromptFactory.outlineResponseFormat())
        let atomizationSchema = deepSeekIRAtomizationSchema(maxNestedBlockDepth: options.maxNestedBlockDepth)

        try writePrettyJSON(outlineSchema, to: outputRoot.appendingPathComponent("outline_strict_tool_schema.json"))
        try writePrettyJSON(atomizationSchema, to: outputRoot.appendingPathComponent("ir_strict_tool_schema.json"))

        if options.dryRunSchema {
            print("[deepseek-strict] dry-run schema written to \(outputRoot.path)")
            return
        }

        let apiKey = try loadSecret(
            repoRoot: repoRoot,
            primaryKey: "DEEPSEEK_API_KEY",
            fallbackKeys: []
        )
        let baseURLString = try loadSecret(
            repoRoot: repoRoot,
            primaryKey: "DEEPSEEK_BASE_URL",
            fallbackKeys: [],
            defaultValue: "https://api.deepseek.com/beta"
        )
        guard let baseURL = URL(string: baseURLString) else {
            throw MissingConfiguration(key: "DEEPSEEK_BASE_URL")
        }

        let models = options.models.isEmpty ? defaultModels : options.models
        let fixtures = try loadFixtureInputs(
            fixtureRoot: fixtureRoot,
            selectedFixtureNames: options.fixtureNames
        )

        print("[deepseek-strict] output=\(outputRoot.path)")
        print("[deepseek-strict] baseURL=\(baseURL.absoluteString)")
        print("[deepseek-strict] models=\(models.joined(separator: ", "))")
        print("[deepseek-strict] fixtures=\(fixtures.map(\.name).joined(separator: ", "))")

        let outlineJobs = models.flatMap { model in
            fixtures.map { fixture in (model: model, fixture: fixture) }
        }
        let outlineResults = await runInBatches(outlineJobs, concurrency: options.concurrency) { job in
            await runOutlineJob(
                model: job.model,
                fixture: job.fixture,
                apiKey: apiKey,
                baseURL: baseURL,
                schema: outlineSchema,
                outputRoot: outputRoot,
                sampleCount: options.sampleCount,
                timeoutSeconds: options.requestTimeoutSeconds
            )
        }

        let atomizationJobs = try outlineResults.flatMap { record -> [(model: String, fixture: FixtureInput, outline: PatternOutlineResponse, roundIndex: Int, sampleOrdinal: Int)] in
            guard record.status == "success", let outlinePath = record.outlinePath else {
                return []
            }
            let outline = try JSONDecoder().decode(
                PatternOutlineResponse.self,
                from: Data(contentsOf: URL(fileURLWithPath: outlinePath))
            )
            guard let fixture = fixtures.first(where: { $0.name == record.fixtureName }) else {
                return []
            }
            return record.sampledRoundIndices.enumerated().map { offset, roundIndex in
                (record.model, fixture, outline, roundIndex, offset + 1)
            }
        }

        let atomizationResults = await runInBatches(atomizationJobs, concurrency: options.concurrency) { job in
            await runAtomizationJob(
                model: job.model,
                fixture: job.fixture,
                outline: job.outline,
                roundIndex: job.roundIndex,
                sampleOrdinal: job.sampleOrdinal,
                apiKey: apiKey,
                baseURL: baseURL,
                schema: atomizationSchema,
                outputRoot: outputRoot,
                timeoutSeconds: options.atomizationTimeoutSeconds ?? options.requestTimeoutSeconds
            )
        }

        let index = RunIndex(
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            baseURL: baseURL.absoluteString,
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
        print("[deepseek-strict] outline success \(outlineSuccess)/\(outlineResults.count)")
        print("[deepseek-strict] atomization success \(atomizationSuccess)/\(atomizationResults.count)")
        print("[deepseek-strict] wrote \(outputRoot.appendingPathComponent("run_index.json").path)")
    }

    private struct Options {
        var outputRoot: String?
        var models: [String] = []
        var fixtureNames: Set<String>?
        var sampleCount = 5
        var concurrency = 1
        var requestTimeoutSeconds: TimeInterval = 300
        var atomizationTimeoutSeconds: TimeInterval?
        var maxNestedBlockDepth = 2
        var dryRunSchema = false
    }

    private func parseOptions(_ args: [String]) throws -> Options {
        var options = Options()
        var index = 0
        while index < args.count {
            let arg = args[index]
            func requireValue() throws -> String {
                let valueIndex = index + 1
                guard valueIndex < args.count else {
                    throw NSError(domain: "DeepSeekStrictToolComparisonRunner", code: -1, userInfo: [
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
                options.models = try requireValue()
                    .split(separator: ",")
                    .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            case "--fixtures":
                let names = try requireValue()
                    .split(separator: ",")
                    .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                options.fixtureNames = Set(names)
            case "--sample-count":
                options.sampleCount = max(1, Int(try requireValue()) ?? 5)
            case "--concurrency":
                options.concurrency = max(1, Int(try requireValue()) ?? 1)
            case "--request-timeout-seconds":
                options.requestTimeoutSeconds = max(1, TimeInterval(Int(try requireValue()) ?? 300))
            case "--atomization-timeout-seconds":
                options.atomizationTimeoutSeconds = max(1, TimeInterval(Int(try requireValue()) ?? 180))
            case "--max-nested-block-depth":
                options.maxNestedBlockDepth = max(0, Int(try requireValue()) ?? 2)
            case "--dry-run-schema":
                options.dryRunSchema = true
            default:
                throw NSError(domain: "DeepSeekStrictToolComparisonRunner", code: -2, userInfo: [
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
                .appendingPathComponent("deepseek-strict-\(formatter.string(from: Date()))")
        }
        try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)
        return outputRoot
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
                throw NSError(domain: "DeepSeekStrictToolComparisonRunner", code: -10, userInfo: [
                    NSLocalizedDescriptionKey: "\(entry.name) has no extracted_text.txt/raw.txt/raw.html"
                ])
            }

            return FixtureInput(
                name: entry.name,
                title: entry.title,
                sourceType: entry.sourceType,
                sourceURL: entry.sourceURL,
                extractedTextPath: sourceURL.path
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
        apiKey: String,
        baseURL: URL,
        schema: [String: Any],
        outputRoot: URL,
        sampleCount: Int,
        timeoutSeconds: TimeInterval
    ) async -> OutlineRunRecord {
        let requestModel = officialDeepSeekModelID(from: model)
        let fixtureDir = outputRoot
            .appendingPathComponent(safePathComponent(model))
            .appendingPathComponent(fixture.name)
        let envelopePath = fixtureDir.appendingPathComponent("outline_envelope.json")
        let argumentsPath = fixtureDir.appendingPathComponent("outline_tool_arguments.json")
        let outlinePath = fixtureDir.appendingPathComponent("outline.json")

        do {
            try FileManager.default.createDirectory(at: fixtureDir, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: outlinePath.path) {
                let outline = try JSONDecoder().decode(
                    PatternOutlineResponse.self,
                    from: Data(contentsOf: outlinePath)
                )
                let roundCount = outline.parts.flatMap(\.rounds).count
                return OutlineRunRecord(
                    model: model,
                    requestModel: requestModel,
                    fixtureName: fixture.name,
                    status: "success",
                    durationMS: nil,
                    responseBytes: nil,
                    envelopePath: FileManager.default.fileExists(atPath: envelopePath.path) ? envelopePath.path : nil,
                    argumentsPath: FileManager.default.fileExists(atPath: argumentsPath.path) ? argumentsPath.path : nil,
                    outlinePath: outlinePath.path,
                    roundCount: roundCount,
                    sampledRoundIndices: sampleIndices(total: roundCount, sampleCount: sampleCount),
                    error: nil
                )
            }

            let extractedText = try String(contentsOfFile: fixture.extractedTextPath, encoding: .utf8)
            let result = try await strictToolCall(
                apiKey: apiKey,
                baseURL: baseURL,
                model: requestModel,
                toolName: "return_crochet_pattern_outline",
                toolDescription: "Return the parsed crochet pattern outline JSON object.",
                parameters: schema,
                systemPrompt: PromptFactory.textOutlineSystemPrompt()
                    + "\n\nYou must call the return_crochet_pattern_outline tool with the parsed JSON. Do not answer in prose.",
                userPrompt: PromptFactory.textOutlinePrompt(extractedText: extractedText, titleHint: fixture.title),
                timeoutSeconds: timeoutSeconds
            )
            try result.envelope.write(to: envelopePath, atomically: true, encoding: .utf8)
            try result.arguments.write(to: argumentsPath, atomically: true, encoding: .utf8)

            let outline = try decodeJSON(PatternOutlineResponse.self, from: result.arguments)
            try writePrettyJSON(outline, to: outlinePath)
            let roundCount = outline.parts.flatMap(\.rounds).count
            print("[deepseek-strict outline] \(model) \(fixture.name): success rounds=\(roundCount)")
            return OutlineRunRecord(
                model: model,
                requestModel: requestModel,
                fixtureName: fixture.name,
                status: "success",
                durationMS: result.durationMS,
                responseBytes: result.responseBytes,
                envelopePath: envelopePath.path,
                argumentsPath: argumentsPath.path,
                outlinePath: outlinePath.path,
                roundCount: roundCount,
                sampledRoundIndices: sampleIndices(total: roundCount, sampleCount: sampleCount),
                error: nil
            )
        } catch {
            let message = String(describing: error)
            try? message.write(to: fixtureDir.appendingPathComponent("outline.error.txt"), atomically: true, encoding: .utf8)
            print("[deepseek-strict outline] \(model) \(fixture.name): failed \(message)")
            return OutlineRunRecord(
                model: model,
                requestModel: requestModel,
                fixtureName: fixture.name,
                status: "failed",
                durationMS: nil,
                responseBytes: nil,
                envelopePath: FileManager.default.fileExists(atPath: envelopePath.path) ? envelopePath.path : nil,
                argumentsPath: FileManager.default.fileExists(atPath: argumentsPath.path) ? argumentsPath.path : nil,
                outlinePath: nil,
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
        apiKey: String,
        baseURL: URL,
        schema: [String: Any],
        outputRoot: URL,
        timeoutSeconds: TimeInterval
    ) async -> AtomizationRunRecord {
        let requestModel = officialDeepSeekModelID(from: model)
        let flatRounds = outline.parts.flatMap { part in
            part.rounds.map { (partName: part.name, round: $0) }
        }
        let pair = flatRounds[roundIndex]
        let round = pair.round
        let caseDir = outputRoot
            .appendingPathComponent(safePathComponent(model))
            .appendingPathComponent(fixture.name)
            .appendingPathComponent("atomization")
            .appendingPathComponent(safePathComponent("\(sampleOrdinal)-\(round.title)"))
        let envelopePath = caseDir.appendingPathComponent("ir_envelope.json")
        let argumentsPath = caseDir.appendingPathComponent("ir_tool_arguments.json")
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
                let snapshot = try JSONDecoder().decode(AtomicRoundSnapshot.self, from: Data(contentsOf: snapshotPath))
                return makeAtomizationRecord(
                    model: model,
                    requestModel: requestModel,
                    fixture: fixture,
                    sampleOrdinal: sampleOrdinal,
                    roundIndex: roundIndex,
                    round: round,
                    status: "success",
                    durationMS: nil,
                    responseBytes: nil,
                    envelopePath: FileManager.default.fileExists(atPath: envelopePath.path) ? envelopePath.path : nil,
                    argumentsPath: FileManager.default.fileExists(atPath: argumentsPath.path) ? argumentsPath.path : nil,
                    irPath: irPath.path,
                    snapshotPath: snapshotPath.path,
                    snapshot: snapshot,
                    error: nil
                )
            }

            let result = try await strictToolCall(
                apiKey: apiKey,
                baseURL: baseURL,
                model: requestModel,
                toolName: "return_crochet_ir_atomization",
                toolDescription: "Return the Crochet IR atomization JSON object.",
                parameters: schema,
                systemPrompt: PromptFactory.roundIRAtomizationSystemPrompt()
                    + "\n\nYou must call the return_crochet_ir_atomization tool with the parsed JSON. Do not answer in prose.",
                userPrompt: PromptFactory.roundIRAtomizationPrompt(
                    projectTitle: outline.projectTitle,
                    materials: outline.materials,
                    rounds: [input]
                ),
                timeoutSeconds: timeoutSeconds
            )
            try result.envelope.write(to: envelopePath, atomically: true, encoding: .utf8)
            try result.arguments.write(to: argumentsPath, atomically: true, encoding: .utf8)

            let ir = try decodeJSON(CrochetIRAtomizationResponse.self, from: result.arguments)
            try writePrettyJSON(ir, to: irPath)
            guard let block = ir.rounds.first else {
                throw NSError(domain: "DeepSeekStrictToolComparisonRunner", code: -20, userInfo: [
                    NSLocalizedDescriptionKey: "atomization returned zero rounds"
                ])
            }
            let snapshot = buildAtomicSnapshot(from: block)
            try writePrettyJSON(snapshot, to: snapshotPath)
            print("[deepseek-strict atomization] \(model) \(fixture.name) \(sampleOrdinal)/\(round.title): success actions=\(snapshot.actions.count)")
            return makeAtomizationRecord(
                model: model,
                requestModel: requestModel,
                fixture: fixture,
                sampleOrdinal: sampleOrdinal,
                roundIndex: roundIndex,
                round: round,
                status: "success",
                durationMS: result.durationMS,
                responseBytes: result.responseBytes,
                envelopePath: envelopePath.path,
                argumentsPath: argumentsPath.path,
                irPath: irPath.path,
                snapshotPath: snapshotPath.path,
                snapshot: snapshot,
                error: nil
            )
        } catch {
            let message = String(describing: error)
            try? message.write(to: caseDir.appendingPathComponent("atomization.error.txt"), atomically: true, encoding: .utf8)
            print("[deepseek-strict atomization] \(model) \(fixture.name) \(sampleOrdinal)/\(round.title): failed \(message)")
            return makeAtomizationRecord(
                model: model,
                requestModel: requestModel,
                fixture: fixture,
                sampleOrdinal: sampleOrdinal,
                roundIndex: roundIndex,
                round: round,
                status: "failed",
                durationMS: nil,
                responseBytes: nil,
                envelopePath: FileManager.default.fileExists(atPath: envelopePath.path) ? envelopePath.path : nil,
                argumentsPath: FileManager.default.fileExists(atPath: argumentsPath.path) ? argumentsPath.path : nil,
                irPath: nil,
                snapshotPath: nil,
                snapshot: nil,
                error: message
            )
        }
    }

    private func makeAtomizationRecord(
        model: String,
        requestModel: String,
        fixture: FixtureInput,
        sampleOrdinal: Int,
        roundIndex: Int,
        round: OutlinedPatternRound,
        status: String,
        durationMS: Int?,
        responseBytes: Int?,
        envelopePath: String?,
        argumentsPath: String?,
        irPath: String?,
        snapshotPath: String?,
        snapshot: AtomicRoundSnapshot?,
        error: String?
    ) -> AtomizationRunRecord {
        AtomizationRunRecord(
            model: model,
            requestModel: requestModel,
            fixtureName: fixture.name,
            sampleOrdinal: sampleOrdinal,
            roundIndex: roundIndex,
            roundTitle: round.title,
            rawInstruction: round.rawInstruction,
            status: status,
            durationMS: durationMS,
            responseBytes: responseBytes,
            envelopePath: envelopePath,
            argumentsPath: argumentsPath,
            irPath: irPath,
            snapshotPath: snapshotPath,
            validationIssues: snapshot?.validationIssues ?? [],
            expansionFailure: snapshot?.expansionFailure,
            producedStitchCount: snapshot?.producedStitchCount,
            warningCount: snapshot?.warnings.count,
            actionCount: snapshot?.actions.count,
            error: error
        )
    }

    private func strictToolCall(
        apiKey: String,
        baseURL: URL,
        model: String,
        toolName: String,
        toolDescription: String,
        parameters: [String: Any],
        systemPrompt: String,
        userPrompt: String,
        timeoutSeconds: TimeInterval
    ) async throws -> ToolCallResult {
        var request = URLRequest(url: baseURL.appending(path: "chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "model": model,
            "temperature": 0,
            "max_tokens": 32000,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt]
            ],
            "tools": [[
                "type": "function",
                "function": [
                    "name": toolName,
                    "description": toolDescription,
                    "strict": true,
                    "parameters": parameters
                ]
            ]]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let started = Date()
        let (data, response) = try await performRequest(request, timeoutSeconds: timeoutSeconds)
        let durationMS = Int(Date().timeIntervalSince(started) * 1000)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let preview = String(data: data, encoding: .utf8).map { String($0.prefix(1500)) } ?? ""
            throw HTTPFailure(statusCode: status, bodyPreview: preview)
        }

        let envelopeString = serializeResponseData(data)
        guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = envelope["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let toolCalls = message["tool_calls"] as? [[String: Any]],
              let function = toolCalls.first?["function"] as? [String: Any] else {
            throw NSError(domain: "DeepSeekStrictToolComparisonRunner", code: -30, userInfo: [
                NSLocalizedDescriptionKey: "response did not contain tool_calls[0].function"
            ])
        }

        let arguments: String
        if let rawArguments = function["arguments"] as? String {
            arguments = rawArguments
        } else if let rawArguments = function["arguments"] {
            arguments = serializeJSONObject(rawArguments)
        } else {
            throw NSError(domain: "DeepSeekStrictToolComparisonRunner", code: -31, userInfo: [
                NSLocalizedDescriptionKey: "tool call did not contain function.arguments"
            ])
        }

        return ToolCallResult(
            arguments: arguments,
            envelope: envelopeString,
            durationMS: durationMS,
            responseBytes: data.count
        )
    }

    private final class URLSessionTaskState: @unchecked Sendable {
        let lock = NSLock()
        var completed = false
        var task: URLSessionDataTask?
    }

    private func performRequest(
        _ request: URLRequest,
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
                        domain: "DeepSeekStrictToolComparisonRunner",
                        code: -32,
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
                continuation.resume(throwing: NSError(
                    domain: "DeepSeekStrictToolComparisonRunner",
                    code: -33,
                    userInfo: [NSLocalizedDescriptionKey: "request timed out after \(Int(timeoutSeconds))s"]
                ))
            }
        }
    }

    private func strictToolSchema(from responseFormat: [String: Any]) throws -> [String: Any] {
        guard let jsonSchema = responseFormat["json_schema"] as? [String: Any],
              let schema = jsonSchema["schema"] as? [String: Any],
              let converted = convertSchemaNode(schema) as? [String: Any] else {
            throw NSError(domain: "DeepSeekStrictToolComparisonRunner", code: -40, userInfo: [
                NSLocalizedDescriptionKey: "could not extract schema from response_format"
            ])
        }
        return converted
    }

    private func convertSchemaNode(_ value: Any) -> Any {
        if let dictionary = value as? [String: Any] {
            var converted: [String: Any] = [:]
            for (key, rawValue) in dictionary {
                let mappedKey = key == "$defs" ? "$def" : key
                if key == "$ref", let ref = rawValue as? String {
                    converted[mappedKey] = ref.replacingOccurrences(of: "#/$defs/", with: "#/$def/")
                } else {
                    converted[mappedKey] = convertSchemaNode(rawValue)
                }
            }

            if let typeArray = dictionary["type"] as? [Any],
               typeArray.contains(where: { ($0 as? String) == "null" }) {
                var base = converted
                base.removeValue(forKey: "type")
                let nonNullTypes = typeArray.compactMap { $0 as? String }.filter { $0 != "null" }
                let variants = nonNullTypes.map { typeName -> [String: Any] in
                    var variant = base
                    variant["type"] = typeName
                    return variant
                } + [["type": "null"]]
                return ["anyOf": variants]
            }

            if let variants = converted["anyOf"] as? [[String: Any]] {
                converted["anyOf"] = variants.map { variant in
                    guard variant["$ref"] != nil, variant["type"] == nil else {
                        return variant
                    }
                    var typedVariant = variant
                    typedVariant["type"] = "object"
                    return typedVariant
                }
            }

            return converted
        }

        if let array = value as? [Any] {
            return array.map(convertSchemaNode)
        }

        return value
    }

    private func deepSeekIRAtomizationSchema(maxNestedBlockDepth: Int) -> [String: Any] {
        let depth = max(0, maxNestedBlockDepth)
        return [
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "rounds": [
                    "type": "array",
                    "items": deepSeekIRInstructionBlockSchema(maxNestedBlockDepth: depth)
                ]
            ],
            "required": ["rounds"]
        ]
    }

    private func deepSeekIRInstructionBlockSchema(maxNestedBlockDepth: Int) -> [String: Any] {
        [
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "title": ["type": "string"],
                "sourceText": ["type": "string"],
                "expectedProducedStitches": deepSeekNullableIntegerSchema(),
                "body": deepSeekIRBlockSchema(nestingDepth: maxNestedBlockDepth)
            ],
            "required": ["title", "sourceText", "expectedProducedStitches", "body"]
        ]
    }

    private func deepSeekIRBlockSchema(nestingDepth: Int) -> [String: Any] {
        [
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "statements": [
                    "type": "array",
                    "items": deepSeekIRStatementSchema(nestingDepth: nestingDepth)
                ],
                "sourceText": deepSeekNullableStringSchema(),
                "normalizationNote": deepSeekNullableStringSchema()
            ],
            "required": ["statements", "sourceText", "normalizationNote"]
        ]
    }

    private func deepSeekIRStatementSchema(nestingDepth: Int) -> [String: Any] {
        let allowsNestedBlocks = nestingDepth > 0
        let allowedKinds = allowsNestedBlocks
            ? CrochetIRStatementKindTag.allCases.map(\.rawValue)
            : [
                CrochetIRStatementKindTag.operation.rawValue,
                CrochetIRStatementKindTag.note.rawValue
            ]
        let repeatSchema = allowsNestedBlocks
            ? deepSeekNullableObjectSchema(deepSeekIRRepeatBlockSchema(childBlockDepth: nestingDepth - 1))
            : deepSeekNullOnlySchema()
        let conditionalSchema = allowsNestedBlocks
            ? deepSeekNullableObjectSchema(deepSeekIRConditionalSchema(childBlockDepth: nestingDepth - 1))
            : deepSeekNullOnlySchema()

        return [
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "kind": [
                    "type": "string",
                    "enum": allowedKinds
                ],
                "sourceText": deepSeekNullableStringSchema(),
                "operation": deepSeekNullableObjectSchema(deepSeekIROperationSchema()),
                "repeat": repeatSchema,
                "conditional": conditionalSchema,
                "note": deepSeekNullableObjectSchema(deepSeekIRNoteSchema())
            ],
            "required": ["kind", "sourceText", "operation", "repeat", "conditional", "note"]
        ]
    }

    private func deepSeekIROperationSchema() -> [String: Any] {
        [
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "semantics": [
                    "type": "string",
                    "enum": CrochetIROperationSemantics.allCases.map(\.rawValue)
                ],
                "actionTag": ["type": "string"],
                "stitch": deepSeekNullableStringSchema(),
                "count": ["type": "integer"],
                "instruction": deepSeekNullableStringSchema(),
                "target": deepSeekNullableStringSchema(),
                "note": deepSeekNullableStringSchema(),
                "notePlacement": [
                    "type": "string",
                    "enum": AtomizedNotePlacement.allCases.map(\.rawValue)
                ],
                "producedStitches": deepSeekNullableIntegerSchema()
            ],
            "required": [
                "semantics",
                "actionTag",
                "stitch",
                "count",
                "instruction",
                "target",
                "note",
                "notePlacement",
                "producedStitches"
            ]
        ]
    }

    private func deepSeekIRRepeatBlockSchema(childBlockDepth: Int) -> [String: Any] {
        [
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "times": ["type": "integer"],
                "body": deepSeekIRBlockSchema(nestingDepth: childBlockDepth),
                "sourceRepeatCount": deepSeekNullableIntegerSchema(),
                "normalizationNote": deepSeekNullableStringSchema()
            ],
            "required": ["times", "body", "sourceRepeatCount", "normalizationNote"]
        ]
    }

    private func deepSeekIRConditionalSchema(childBlockDepth: Int) -> [String: Any] {
        [
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "choiceID": ["type": "string"],
                "question": ["type": "string"],
                "branches": [
                    "type": "array",
                    "items": deepSeekIRConditionalBranchSchema(childBlockDepth: childBlockDepth)
                ],
                "defaultBranchValue": deepSeekNullableStringSchema(),
                "commonBody": deepSeekNullableObjectSchema(deepSeekIRBlockSchema(nestingDepth: childBlockDepth))
            ],
            "required": ["choiceID", "question", "branches", "defaultBranchValue", "commonBody"]
        ]
    }

    private func deepSeekIRConditionalBranchSchema(childBlockDepth: Int) -> [String: Any] {
        [
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "value": ["type": "string"],
                "label": ["type": "string"],
                "body": deepSeekIRBlockSchema(nestingDepth: childBlockDepth)
            ],
            "required": ["value", "label", "body"]
        ]
    }

    private func deepSeekIRNoteSchema() -> [String: Any] {
        [
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "message": ["type": "string"],
                "sourceText": deepSeekNullableStringSchema(),
                "emitAsAction": ["type": "boolean"]
            ],
            "required": ["message", "sourceText", "emitAsAction"]
        ]
    }

    private func deepSeekNullableObjectSchema(_ objectSchema: [String: Any]) -> [String: Any] {
        [
            "anyOf": [
                objectSchema,
                deepSeekNullOnlySchema()
            ]
        ]
    }

    private func deepSeekNullableStringSchema() -> [String: Any] {
        [
            "anyOf": [
                ["type": "string"],
                deepSeekNullOnlySchema()
            ]
        ]
    }

    private func deepSeekNullableIntegerSchema() -> [String: Any] {
        [
            "anyOf": [
                ["type": "integer"],
                deepSeekNullOnlySchema()
            ]
        ]
    }

    private func deepSeekNullOnlySchema() -> [String: Any] {
        ["type": "null"]
    }

    private func officialDeepSeekModelID(from model: String) -> String {
        if model.hasPrefix("deepseek/") {
            return String(model.dropFirst("deepseek/".count))
        }
        return model
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

    private func loadSecret(
        repoRoot: URL,
        primaryKey: String,
        fallbackKeys: [String],
        defaultValue: String? = nil
    ) throws -> String {
        let env = ProcessInfo.processInfo.environment
        for key in [primaryKey] + fallbackKeys {
            if let value = env[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
        }

        let secretsURL = repoRoot.appendingPathComponent("Config/Secrets.xcconfig")
        let raw = (try? String(contentsOf: secretsURL, encoding: .utf8)) ?? ""
        var values: [String: String] = ["SLASH": "/"]
        for line in raw.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("//"), let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[..<eq].trimmingCharacters(in: .whitespaces)
            let value = trimmed[trimmed.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            values[key] = value
        }

        func resolve(_ value: String) -> String {
            var result = value
            while let range = result.range(of: #"\$\([A-Z_]+\)"#, options: .regularExpression) {
                let key = String(result[range]).dropFirst(2).dropLast()
                result.replaceSubrange(range, with: values[String(key)] ?? "")
            }
            return result.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        for key in [primaryKey] + fallbackKeys {
            if let rawValue = values[key] {
                let value = resolve(rawValue)
                if !value.isEmpty { return value }
            }
        }

        if let defaultValue { return defaultValue }
        throw MissingConfiguration(key: primaryKey)
    }

    private func writePrettyJSON<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        try data.write(to: url)
    }

    private func writePrettyJSON(_ value: Any, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url)
    }

    private func serializeResponseData(_ data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) {
            return serializeJSONObject(object)
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func serializeJSONObject(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return String(describing: value)
        }
        return string
    }

    private func writeMarkdownSummary(_ index: RunIndex, to url: URL) throws {
        var lines: [String] = []
        lines.append("# DeepSeek Strict Tool Comparison")
        lines.append("")
        lines.append("- Generated: \(index.generatedAt)")
        lines.append("- Base URL: \(index.baseURL)")
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
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
