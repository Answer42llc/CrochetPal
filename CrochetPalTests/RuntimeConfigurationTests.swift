import XCTest
@testable import CrochetPal

final class RuntimeConfigurationTests: XCTestCase {
    func testConfigurationLoadsFromDictionary() throws {
        let configuration = try RuntimeConfiguration.load(values: [
            "OPENAI_API_KEY": "key",
            "OPENAI_BASE_URL": "https://example.com/v1/",
            "TEXT_MODEL_ID": "text-model",
            "ATOMIZATION_MODEL_ID": "atomization-model",
            "VISION_MODEL_ID": "vision-model"
        ])

        XCTAssertEqual(configuration.apiKey, "key")
        XCTAssertEqual(configuration.textModelID, "text-model")
        XCTAssertEqual(configuration.atomizationModelID, "atomization-model")
        XCTAssertEqual(configuration.visionModelID, "vision-model")
    }

    func testConfigurationTrimsQuotedValues() throws {
        let configuration = try RuntimeConfiguration.load(values: [
            "OPENAI_API_KEY": "\"key\"",
            "OPENAI_BASE_URL": "\"https://example.com/v1/\"",
            "TEXT_MODEL_ID": "\"text-model\"",
            "ATOMIZATION_MODEL_ID": "\"atomization-model\"",
            "VISION_MODEL_ID": "\"vision-model\""
        ])

        XCTAssertEqual(configuration.apiKey, "key")
        XCTAssertEqual(configuration.baseURL.absoluteString, "https://example.com/v1/")
        XCTAssertEqual(configuration.textModelID, "text-model")
        XCTAssertEqual(configuration.atomizationModelID, "atomization-model")
        XCTAssertEqual(configuration.visionModelID, "vision-model")
    }

    func testAtomizationModelFallsBackToTextModel() throws {
        let configuration = try RuntimeConfiguration.load(values: [
            "OPENAI_API_KEY": "key",
            "OPENAI_BASE_URL": "https://example.com/v1/",
            "TEXT_MODEL_ID": "text-model",
            "VISION_MODEL_ID": "vision-model"
        ])

        XCTAssertEqual(configuration.atomizationModelID, "text-model")
    }
}
