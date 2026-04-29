import Foundation

struct RuntimeConfiguration: Hashable {
    var apiKey: String
    var baseURL: URL
    var deepSeekAPIKey: String?
    var deepSeekBaseURL: URL?
    var textModelID: String
    var atomizationModelID: String
    var visionModelID: String

    static func load(bundle: Bundle = .main) throws -> RuntimeConfiguration {
        let environment = ProcessInfo.processInfo.environment
        return try load(values: [
            "OPENAI_API_KEY": bundle.stringValue(forInfoKey: "OPENAI_API_KEY").ifEmpty(environment["OPENAI_API_KEY"]),
            "OPENAI_BASE_URL": bundle.stringValue(forInfoKey: "OPENAI_BASE_URL").ifEmpty(environment["OPENAI_BASE_URL"]),
            "DEEPSEEK_API_KEY": bundle.stringValue(forInfoKey: "DEEPSEEK_API_KEY").ifEmpty(environment["DEEPSEEK_API_KEY"]),
            "DEEPSEEK_BASE_URL": bundle.stringValue(forInfoKey: "DEEPSEEK_BASE_URL").ifEmpty(environment["DEEPSEEK_BASE_URL"]),
            "TEXT_MODEL_ID": bundle.stringValue(forInfoKey: "TEXT_MODEL_ID").ifEmpty(environment["TEXT_MODEL_ID"]),
            "ATOMIZATION_MODEL_ID": bundle.stringValue(forInfoKey: "ATOMIZATION_MODEL_ID").ifEmpty(environment["ATOMIZATION_MODEL_ID"]),
            "VISION_MODEL_ID": bundle.stringValue(forInfoKey: "VISION_MODEL_ID").ifEmpty(environment["VISION_MODEL_ID"])
        ])
    }

    static func load(values: [String: String]) throws -> RuntimeConfiguration {
        let apiKey = sanitize(values["OPENAI_API_KEY"])
        let baseURLString = sanitize(values["OPENAI_BASE_URL"])
        let deepSeekAPIKey = sanitize(values["DEEPSEEK_API_KEY"]).nilIfEmpty
        let deepSeekBaseURLString = sanitize(values["DEEPSEEK_BASE_URL"])
        let textModelID = sanitize(values["TEXT_MODEL_ID"])
        let atomizationModelID = sanitize(values["ATOMIZATION_MODEL_ID"]).ifEmpty(textModelID)
        let visionModelID = sanitize(values["VISION_MODEL_ID"])

        guard !apiKey.isEmpty else {
            throw PatternImportFailure.missingConfiguration("OPENAI_API_KEY")
        }
        guard let baseURL = URL(string: baseURLString), !baseURLString.isEmpty else {
            throw PatternImportFailure.missingConfiguration("OPENAI_BASE_URL")
        }
        let deepSeekBaseURL: URL?
        if deepSeekBaseURLString.isEmpty {
            deepSeekBaseURL = nil
        } else if let url = URL(string: deepSeekBaseURLString) {
            deepSeekBaseURL = url
        } else {
            throw PatternImportFailure.missingConfiguration("DEEPSEEK_BASE_URL")
        }
        guard !textModelID.isEmpty else {
            throw PatternImportFailure.missingConfiguration("TEXT_MODEL_ID")
        }
        guard !visionModelID.isEmpty else {
            throw PatternImportFailure.missingConfiguration("VISION_MODEL_ID")
        }

        return RuntimeConfiguration(
            apiKey: apiKey,
            baseURL: baseURL,
            deepSeekAPIKey: deepSeekAPIKey,
            deepSeekBaseURL: deepSeekBaseURL,
            textModelID: textModelID,
            atomizationModelID: atomizationModelID,
            visionModelID: visionModelID
        )
    }

    private static func sanitize(_ value: String?) -> String {
        (value ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            .nilIfBuildSettingPlaceholder
    }
}

extension Bundle {
    func stringValue(forInfoKey key: String) -> String {
        object(forInfoDictionaryKey: key) as? String ?? ""
    }
}

private extension String {
    func ifEmpty(_ fallback: String?) -> String {
        isEmpty ? (fallback ?? "") : self
    }

    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }

    var nilIfBuildSettingPlaceholder: String {
        hasPrefix("$(") && hasSuffix(")") ? "" : self
    }
}
