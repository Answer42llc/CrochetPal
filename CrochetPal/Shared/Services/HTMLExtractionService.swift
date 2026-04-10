import Foundation
import SwiftSoup

protocol HTMLExtracting {
    func extract(
        from html: String,
        sourceURL: URL?,
        context: ParseRequestContext,
        logger: TraceLogging
    ) -> WebExtractionResult
}

struct HTMLExtractionService: HTMLExtracting {
    private let removableSelectors = "script, style, noscript, svg, nav, footer, aside, form, header, iframe"

    func extract(
        from html: String,
        sourceURL: URL?,
        context: ParseRequestContext,
        logger: TraceLogging
    ) -> WebExtractionResult {
        do {
            let document = try parseHTMLDocument(from: html, sourceURL: sourceURL)
            let title = try normalizedTitle(from: document)

            let removableElements = try document.select(removableSelectors)
            try removableElements.remove()

            let textSegments = extractTextSegments(from: document.body())
            let reducedHTMLLength = try document.body()?.html().count ?? 0

            logger.log(LogEvent(
                timestamp: .now,
                level: "debug",
                traceID: context.traceID,
                parseRequestID: context.parseRequestID,
                projectID: nil,
                sourceType: .web,
                stage: "web_extraction",
                decision: "swift_soup",
                reason: "extracted_text_nodes",
                durationMS: nil,
                metadata: [
                    "url": sourceURL?.absoluteString ?? "",
                    "rawHTMLLength": "\(html.count)",
                    "reducedHTMLLength": "\(reducedHTMLLength)",
                    "blockCount": "\(textSegments.count)",
                    "keptBlockCount": "\(textSegments.count)"
                ]
            ))

            return WebExtractionResult(
                title: title,
                keptBlocks: textSegments,
                decisions: textSegments.enumerated().map { index, segment in
                    ExtractionDecision(
                        index: index,
                        preview: segment,
                        score: 1,
                        keep: true,
                        reasons: ["swift_soup_text_segment"]
                    )
                },
                finalText: textSegments.joined(separator: "\n"),
                fallbackUsed: false,
                rawHTMLLength: html.count,
                reducedHTMLLength: reducedHTMLLength
            )
        } catch {
            logger.log(LogEvent(
                timestamp: .now,
                level: "error",
                traceID: context.traceID,
                parseRequestID: context.parseRequestID,
                projectID: nil,
                sourceType: .web,
                stage: "web_extraction",
                decision: "failure",
                reason: "swift_soup_parse_failed",
                durationMS: nil,
                metadata: [
                    "url": sourceURL?.absoluteString ?? "",
                    "error": String(describing: error),
                    "rawHTMLLength": "\(html.count)"
                ]
            ))

            return WebExtractionResult(
                title: nil,
                keptBlocks: [],
                decisions: [],
                finalText: "",
                fallbackUsed: false,
                rawHTMLLength: html.count,
                reducedHTMLLength: 0
            )
        }
    }

    private func parseHTMLDocument(from html: String, sourceURL: URL?) throws -> Document {
        try SwiftSoup.parseHTML(html, sourceURL?.absoluteString ?? "")
    }

    private func normalizedTitle(from document: Document) throws -> String? {
        let title = try normalizeExtractedText(document.title())
        return title.isEmpty ? nil : title
    }

    private func extractTextSegments(from root: Element?) -> [String] {
        guard let root else {
            return []
        }

        var segments: [String] = []
        var currentSegment = ""

        func flushCurrentSegment() {
            let normalized = normalizeExtractedText(currentSegment)
            guard !normalized.isEmpty else {
                currentSegment = ""
                return
            }
            segments.append(normalized)
            currentSegment = ""
        }

        func walk(_ node: Node) {
            if let textNode = node as? TextNode {
                let rawText = textNode.getWholeText()
                if !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    currentSegment.append(rawText)
                }
                return
            }

            guard let element = node as? Element else {
                return
            }

            let tagName = element.tag().getNameNormal()
            if tagName == "br" {
                flushCurrentSegment()
                return
            }

            if element.isBlock(), !currentSegment.isEmpty {
                flushCurrentSegment()
            }

            for child in element.getChildNodes() {
                walk(child)
            }

            if element.isBlock() {
                flushCurrentSegment()
            }
        }

        for child in root.getChildNodes() {
            walk(child)
        }
        flushCurrentSegment()

        return segments
    }

    private func normalizeExtractedText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\u{00a0}", with: " ")
            .replacingOccurrences(of: "\u{00d7}", with: "x")
            .replacingOccurrences(of: "\u{2013}", with: "-")
            .replacingOccurrences(of: "\u{2014}", with: "-")
            .replacingOccurrences(of: "\u{2018}", with: "'")
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{201c}", with: "\"")
            .replacingOccurrences(of: "\u{201d}", with: "\"")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
