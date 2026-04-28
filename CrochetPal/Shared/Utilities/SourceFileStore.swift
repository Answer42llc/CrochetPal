import Foundation

/// Persists copies of imported pattern source files (images, PDFs) to disk so the UI can
/// later present the original to the user via QuickLook.
///
/// Files are stored under a single subdirectory of Application Support and referenced by
/// a relative path saved on `PatternSource.localFilePath`. Callers should treat the
/// returned path as opaque and use `resolveURL(forRelativePath:)` to obtain a usable URL.
protocol SourceFileStoring {
    /// Writes `data` to disk and returns the relative path to be saved on the project.
    /// The provided `fileName` is only used to derive an extension — the actual on-disk
    /// name is uniquified so concurrent imports of the same name don't collide.
    func saveSourceFile(data: Data, fileName: String) throws -> String

    /// Resolves a previously-saved relative path to an absolute URL, or `nil` if the
    /// underlying file no longer exists.
    func resolveURL(forRelativePath relativePath: String) -> URL?
}

final class SourceFileStore: SourceFileStoring {
    private let baseDirectoryURL: URL
    private let subdirectoryName = "SourceFiles"

    init(baseDirectoryURL: URL? = nil) {
        self.baseDirectoryURL = baseDirectoryURL
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    func saveSourceFile(data: Data, fileName: String) throws -> String {
        let directoryURL = baseDirectoryURL.appendingPathComponent(subdirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let ext = (fileName as NSString).pathExtension
        let uniqueName = ext.isEmpty
            ? UUID().uuidString
            : "\(UUID().uuidString).\(ext)"

        let fileURL = directoryURL.appendingPathComponent(uniqueName)
        try data.write(to: fileURL, options: [.atomic])

        return "\(subdirectoryName)/\(uniqueName)"
    }

    func resolveURL(forRelativePath relativePath: String) -> URL? {
        let fileURL = baseDirectoryURL.appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }
        return fileURL
    }
}
