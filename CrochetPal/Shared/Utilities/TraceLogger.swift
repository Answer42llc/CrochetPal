import Foundation
import OSLog

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

struct ConsoleTraceLogger: TraceLogging {
    private let logger = Logger(subsystem: "CrochetPal", category: "Trace")
    private let sinkID: UUID

    @MainActor
    private static var sinks: [UUID: (LogEvent) -> Void] = [:]

    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    init(sink: ((LogEvent) -> Void)? = nil) {
        let sinkID = UUID()
        self.sinkID = sinkID
        Self.sinks[sinkID] = sink
    }

    func updateSink(_ sink: ((LogEvent) -> Void)?) {
        Self.sinks[sinkID] = sink
    }

    func log(_ event: LogEvent) {
        Self.sinks[sinkID]?(event)
        guard !Self.isRunningTests else { return }
        FileTraceLogSink.shared.write(event)
#if DEBUG
        if let data = try? JSONEncoder.traceEncoder.encode(event),
           let text = String(data: data, encoding: .utf8) {
            logger.debug("\(text, privacy: .public)")
            print(text)
            return
        }
#endif
        logger.debug("\(event.stage, privacy: .public) \(event.decision, privacy: .public): \(event.reason, privacy: .public)")
    }
}

extension JSONEncoder {
    static var traceEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
