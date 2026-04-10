import Foundation

protocol JSONFileStoring {
    func load<T: Decodable>(_ type: T.Type, from filename: String) throws -> T?
    func save<T: Encodable>(_ value: T, to filename: String) throws
}

final class JSONFileStore: JSONFileStoring {
    private let directoryURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(directoryURL: URL? = nil) {
        self.directoryURL = directoryURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder.dateDecodingStrategy = .iso8601
    }

    func load<T>(_ type: T.Type, from filename: String) throws -> T? where T : Decodable {
        let fileURL = try prepareFileURL(filename: filename)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        return try decoder.decode(T.self, from: data)
    }

    func save<T>(_ value: T, to filename: String) throws where T : Encodable {
        let fileURL = try prepareFileURL(filename: filename)
        let data = try encoder.encode(value)
        try data.write(to: fileURL, options: [.atomic])
    }

    private func prepareFileURL(filename: String) throws -> URL {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)
        return directoryURL.appendingPathComponent(filename)
    }
}
