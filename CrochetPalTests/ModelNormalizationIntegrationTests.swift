import XCTest
@testable import CrochetPal

final class ModelNormalizationIntegrationTests: XCTestCase {
    func testConfiguredModelsNormalizeWolfRoundOne() async throws {
        let environment = ProcessInfo.processInfo.environment
        let bundle = Bundle.main

        guard normalizationTestsEnabled(environment: environment, bundle: bundle) else {
            throw XCTSkip("设置 RUN_MODEL_NORMALIZATION_TESTS=1 后才运行真实模型归一化测试。")
        }

        let modelIDs = configuredModelIDs(from: environment, bundle: bundle)
        guard !modelIDs.isEmpty else {
            throw XCTSkip("没有可用的测试模型。")
        }

        var failures: [String] = []
        for modelID in modelIDs {
            do {
                try await verifyWolfRoundOneNormalization(using: modelID, environment: environment, bundle: bundle)
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                failures.append("[\(modelID)] \(message)")
            }
        }

        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    private func verifyWolfRoundOneNormalization(
        using modelID: String,
        environment: [String: String],
        bundle: Bundle
    ) async throws {
        let config = try integrationConfiguration(modelID: modelID, environment: environment, bundle: bundle)
        let eventCapture = IntegrationEventCapture()
        let logger = ConsoleTraceLogger { eventCapture.events.append($0) }
        let extractor = HTMLExtractionService()
        let client = OpenAICompatibleLLMClient(configuration: config, logger: logger)
        let importer = PatternImportService(
            parserClient: client,
            extractor: extractor,
            logger: logger
        )

        let sourceURL = try XCTUnwrap(URL(string: "https://grannysquare.me/wolf-granny-square/#pattern"))
        let (data, response) = try await URLSession.shared.data(from: sourceURL)
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertTrue((200..<300).contains(httpResponse.statusCode))

        let html = String(decoding: data, as: UTF8.self)
        let extraction = extractor.extract(
            from: html,
            sourceURL: sourceURL,
            context: ParseRequestContext(traceID: UUID().uuidString, parseRequestID: UUID().uuidString, sourceType: .web),
            logger: logger
        )

        let roundInstruction = "With grey yarn: Magic loop, ch1, 7sc, slst to the first sc."
        XCTAssertTrue(extraction.finalText.contains(roundInstruction))

        let project = makeSingleRoundProject(rawInstruction: roundInstruction)
        let part = try XCTUnwrap(project.parts.first)
        let round = try XCTUnwrap(part.rounds.first)
        let target = RoundReference(partID: part.id, roundID: round.id)
        let updates: [AtomizedRoundUpdate]
        do {
            updates = try await importer.atomizeRounds(in: project, targets: [target])
        } catch {
            throw IntegrationDiagnosticError(
                baseError: error,
                diagnostics: recentDiagnostics(from: eventCapture.events)
            )
        }
        let actions = try XCTUnwrap(updates.first?.atomicActions)

        let actionSequence = actions.map { $0.stitchTag ?? $0.actionTag }.joined(separator: " -> ")
        let producedStitches = actions.reduce(0) { $0 + $1.producedStitches }
        print("[Normalization][\(modelID)] actions=\(actionSequence) produced=\(producedStitches)")

        let tags = actions.map { $0.stitchTag ?? $0.actionTag }
        XCTAssertEqual(tags, ["mr", "ch", "sc", "sc", "sc", "sc", "sc", "sc", "sc", "slst"])
        XCTAssertEqual(actions.reduce(0) { total, action in
            total + (action.stitchTag == "sc" ? 1 : 0)
        }, 7)
        XCTAssertEqual(producedStitches, 7)
    }

    private func normalizationTestsEnabled(environment: [String: String], bundle: Bundle) -> Bool {
        environment["RUN_MODEL_NORMALIZATION_TESTS"] == "1"
            || bundle.stringValue(forInfoKey: "RUN_MODEL_NORMALIZATION_TESTS") == "1"
    }

    private func configuredModelIDs(from environment: [String: String], bundle: Bundle) -> [String] {
        if let rawModels = configuredModelList(
            environment: environment,
            bundle: bundle,
            key: "NORMALIZATION_TEST_MODELS"
        ) {
            return rawModels
        }

        if let configured = configuredValue(
            environment: environment,
            bundle: bundle,
            key: "ATOMIZATION_MODEL_ID"
        ),
           !configured.isEmpty {
            return [configured]
        }

        if let configured = configuredValue(
            environment: environment,
            bundle: bundle,
            key: "TEXT_MODEL_ID"
        ),
           !configured.isEmpty {
            return [configured]
        }

        return ["openai/gpt-5.4"]
    }

    private func configuredModelList(
        environment: [String: String],
        bundle: Bundle,
        key: String
    ) -> [String]? {
        if let rawModels = configuredValue(environment: environment, bundle: bundle, key: key)?
            .split(separator: ",")
            .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
           .filter({ !$0.isEmpty }),
           !rawModels.isEmpty {
            return rawModels
        }

        return nil
    }

    private func configuredValue(
        environment: [String: String],
        bundle: Bundle,
        key: String
    ) -> String? {
        let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let value, !value.isEmpty {
            return value
        }

        let bundleValue = bundle.stringValue(forInfoKey: key).trimmingCharacters(in: .whitespacesAndNewlines)
        return bundleValue.isEmpty ? nil : bundleValue
    }

    private func integrationConfiguration(
        modelID: String,
        environment: [String: String],
        bundle: Bundle
    ) throws -> RuntimeConfiguration {
        let baseConfiguration = try RuntimeConfiguration.load(bundle: bundle)
        let textModelID = configuredValue(
            environment: environment,
            bundle: bundle,
            key: "TEXT_MODEL_ID"
        ) ?? baseConfiguration.textModelID
        let visionModelID = configuredValue(
            environment: environment,
            bundle: bundle,
            key: "VISION_MODEL_ID"
        ) ?? baseConfiguration.visionModelID

        return RuntimeConfiguration(
            apiKey: baseConfiguration.apiKey,
            baseURL: baseConfiguration.baseURL,
            deepSeekAPIKey: baseConfiguration.deepSeekAPIKey,
            deepSeekBaseURL: baseConfiguration.deepSeekBaseURL,
            textModelID: textModelID,
            atomizationModelID: modelID,
            visionModelID: visionModelID
        )
    }

    private func makeSingleRoundProject(rawInstruction: String) -> CrochetProject {
        let round = PatternRound(
            title: "Round 1",
            rawInstruction: rawInstruction,
            summary: "Verify atomization normalization against the live model.",
            targetStitchCount: 7,
            atomizationStatus: .pending,
            atomizationError: nil,
            atomicActions: []
        )

        let part = PatternPart(name: "Wolf Head", rounds: [round])
        return CrochetProject(
            title: "Wolf Granny Square",
            source: PatternSource(
                type: .web,
                displayName: "Wolf Granny Square",
                sourceURL: "https://grannysquare.me/wolf-granny-square/#pattern",
                fileName: nil,
                fileSizeBytes: nil,
                importedAt: .now
            ),
            materials: ["Grey yarn"],
            confidence: 1,
            abbreviations: [],
            parts: [part],
            activePartID: part.id,
            createdAt: .now,
            updatedAt: .now
        )
    }
}

private struct IntegrationDiagnosticError: LocalizedError {
    let baseError: Error
    let diagnostics: String

    var errorDescription: String? {
        let baseDescription = (baseError as? LocalizedError)?.errorDescription ?? baseError.localizedDescription
        guard !diagnostics.isEmpty else {
            return baseDescription
        }
        return "\(baseDescription)\n\nRecent trace diagnostics:\n\(diagnostics)"
    }
}

private final class IntegrationEventCapture: @unchecked Sendable {
    var events: [LogEvent] = []
}

private func recentDiagnostics(from events: [LogEvent]) -> String {
    let relevantStages: Set<String> = [
        "llm_request_payload",
        "llm_request",
        "llm_response_payload",
        "llm_repair",
        "llm_decode"
    ]

    let relevantEvents = events
        .filter { relevantStages.contains($0.stage) }
        .suffix(8)

    guard !relevantEvents.isEmpty else {
        return ""
    }

    return relevantEvents.map { event in
        let metadata = event.metadata
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "\n")
        return """
        [\(event.stage)] \(event.decision) / \(event.reason)
        \(metadata)
        """
    }.joined(separator: "\n\n")
}
