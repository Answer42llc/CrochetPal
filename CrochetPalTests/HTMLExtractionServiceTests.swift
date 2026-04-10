import XCTest
@testable import CrochetPal

final class HTMLExtractionServiceTests: XCTestCase {
    func testExtractorRemovesStructuralTagsAndKeepsRemainingTextNodes() throws {
        let html = try fixture(named: "mouse-pattern", extension: "html")
        let extractor = HTMLExtractionService()
        let logger = ConsoleTraceLogger()
        let context = ParseRequestContext(traceID: "trace", parseRequestID: "parse", sourceType: .web)

        let result = extractor.extract(from: html, sourceURL: URL(string: "https://example.com"), context: context, logger: logger)

        XCTAssertTrue(result.finalText.contains("Mouse Cat Toy Crochet Pattern"))
        XCTAssertTrue(result.finalText.contains("I made this tiny mouse for my cat and she loved it."))
        XCTAssertTrue(result.finalText.contains("Be sure to subscribe for more adorable crochet ideas."))
        XCTAssertTrue(result.finalText.contains("Round 1: In a MR, sc 6. (6)"))
        XCTAssertTrue(result.finalText.contains("Round 2: (sc 2, inc) x 3. (12)"))
        XCTAssertTrue(result.finalText.contains("Comments"))
        XCTAssertTrue(result.finalText.contains("Mary: Love this pattern!"))
        XCTAssertFalse(result.finalText.contains("Home / Free Patterns / Crochet"))
        XCTAssertFalse(result.finalText.contains("Related posts and recommendations"))
    }

    func testExtractorNormalizesUnicodeMultiplicationSign() throws {
        let html = """
        <html><body>
        <p>Round 2: (sc, inc) \u{00d7}3. (9)</p>
        <p>Round 3: (sc 2, inc) \u{00d7}3. (12)</p>
        </body></html>
        """
        let extractor = HTMLExtractionService()
        let logger = ConsoleTraceLogger()
        let context = ParseRequestContext(traceID: "trace", parseRequestID: "parse", sourceType: .web)

        let result = extractor.extract(from: html, sourceURL: nil, context: context, logger: logger)

        XCTAssertFalse(result.finalText.contains("\u{00d7}"), "Unicode multiplication sign should be normalized to x")
        XCTAssertTrue(result.finalText.contains("x3"))
    }

    func testExtractorPreservesInlineTextOrderAcrossNestedTags() throws {
        let html = """
        <html><body>
        <article>
          <p>Round <strong>1</strong>: sc 6 &amp; inc \u{00d7}3.</p>
        </article>
        </body></html>
        """
        let extractor = HTMLExtractionService()
        let logger = ConsoleTraceLogger()
        let context = ParseRequestContext(traceID: "trace", parseRequestID: "parse", sourceType: .web)

        let result = extractor.extract(from: html, sourceURL: nil, context: context, logger: logger)

        XCTAssertTrue(result.finalText.contains("Round 1: sc 6 & inc x3."))
    }

    func testExtractorOnlyUsesTitleAndBodyAndRemovesHeaderAndIframe() throws {
        let html = """
        <html>
          <head>
            <title>Pattern Title</title>
            <meta name="description" content="ignored">
          </head>
          <body>
            <header>Site Header Navigation</header>
            <main>
              <h1>Body Title</h1>
              <p>Round 1: In a MR, sc 6. (6)</p>
              <iframe>Embedded Pattern Widget</iframe>
            </main>
          </body>
        </html>
        """
        let extractor = HTMLExtractionService()
        let logger = ConsoleTraceLogger()
        let context = ParseRequestContext(traceID: "trace", parseRequestID: "parse", sourceType: .web)

        let result = extractor.extract(from: html, sourceURL: nil, context: context, logger: logger)

        XCTAssertEqual(result.title, "Pattern Title")
        XCTAssertTrue(result.finalText.contains("Body Title"))
        XCTAssertTrue(result.finalText.contains("Round 1: In a MR, sc 6. (6)"))
        XCTAssertFalse(result.finalText.contains("Site Header Navigation"))
        XCTAssertFalse(result.finalText.contains("Embedded Pattern Widget"))
    }

    private func fixture(named name: String, extension fileExtension: String) throws -> String {
        let bundle = Bundle(for: Self.self)
        let url = try XCTUnwrap(bundle.url(forResource: name, withExtension: fileExtension))
        return try String(contentsOf: url)
    }
}
