import Foundation

final class FileTraceLogSink: @unchecked Sendable {
    static let shared = FileTraceLogSink()

    private let queue = DispatchQueue(label: "CrochetPal.FileTraceLogSink")
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let maxLines: Int
    private let trimEveryNWrites: Int
    private var writesSinceLastTrim: Int = 0
    private let isDisabled: Bool

    init(
        directoryURL: URL? = nil,
        fileName: String = "trace_logs.jsonl",
        maxLines: Int = 2000,
        trimEveryNWrites: Int = 100
    ) {
        self.isDisabled = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        let base = directoryURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.fileURL = base.appendingPathComponent(fileName)
        self.encoder = JSONEncoder.traceEncoder
        self.maxLines = maxLines
        self.trimEveryNWrites = trimEveryNWrites
    }

    func write(_ event: LogEvent) {
        guard !isDisabled else { return }
        queue.async { [weak self] in
            self?.writeSync(event)
        }
    }

    private func writeSync(_ event: LogEvent) {
        do {
            let fileManager = FileManager.default
            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if !fileManager.fileExists(atPath: fileURL.path) {
                fileManager.createFile(atPath: fileURL.path, contents: nil)
            }

            var payload = try encoder.encode(event)
            payload.append(0x0A)

            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: payload)

            writesSinceLastTrim += 1
            if writesSinceLastTrim >= trimEveryNWrites {
                writesSinceLastTrim = 0
                try trimIfNeeded()
            }
        } catch {
            // Silent failure: logging must never break the app.
        }
    }

    private func trimIfNeeded() throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        let data = try Data(contentsOf: fileURL)
        guard let text = String(data: data, encoding: .utf8) else { return }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.count > maxLines else { return }
        let kept = lines.suffix(maxLines).joined(separator: "\n") + "\n"
        guard let trimmed = kept.data(using: .utf8) else { return }
        try trimmed.write(to: fileURL, options: .atomic)
    }
}
