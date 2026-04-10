import XCTest
@testable import CrochetPal

final class TraceLoggerTests: XCTestCase {
    func testLoggerSendsStructuredEventToSink() {
        var events: [LogEvent] = []
        let logger = ConsoleTraceLogger { events.append($0) }
        logger.log(
            LogEvent(
                timestamp: .now,
                level: "debug",
                traceID: "trace",
                parseRequestID: "parse",
                projectID: nil,
                sourceType: .web,
                stage: "stage",
                decision: "decision",
                reason: "reason",
                durationMS: 12,
                metadata: ["k": "v"]
            )
        )

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.metadata["k"], "v")
    }
}
