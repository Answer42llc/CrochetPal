import Foundation
import PDFKit
import Vision
#if canImport(UIKit)
import UIKit
#endif

/// PDF 页面解析结果（单页）。`text` 是文字层原文；`ocr` 是对渲染图做本地 OCR 后的结果。
struct PDFPageStats: Codable, Hashable {
    var pageIndex: Int
    var textLayerCharacterCount: Int
    var ocrCharacterCount: Int
    var ocrObservationCount: Int
    var renderedImageBytes: Int
}

struct PDFExtractionResult: Codable, Hashable {
    var title: String?
    var finalText: String
    var perPageStats: [PDFPageStats]
    var truncated: Bool
}

protocol PDFExtracting {
    func extract(
        from data: Data,
        context: ParseRequestContext,
        logger: TraceLogging
    ) async throws -> PDFExtractionResult
}

/// 默认 PDF 抽取实现：PDFKit 拿文字层 + 渲染每页 → Apple Vision 本地 OCR → 合并文本。
///
/// 设计要点（对应 CLAUDE.md 低耦合高复用）：
/// - 单一职责：只负责把 PDF 数据变成"纯文本 + 元数据"；下游与 PDF 无关。
/// - 完全使用 iOS 原生框架（PDFKit + Vision），零第三方依赖。
/// - 不做正则清洗 LLM 输出：此处清洗的是 OCR 输入源，仍保持最小化。
struct PDFExtractionService: PDFExtracting {
    /// 单次导入处理的最大页数。超出会截断并日志记录。
    /// 理由：Vision OCR 每页在 iPhone 15 级设备约 0.2–0.5s；
    ///      20 页覆盖几乎所有独立 Pattern PDF，并为大型合集提供保护上限。
    let maxPages: Int
    /// 渲染 PDF 页面的目标长边像素数。1800–2200 对 Apple Vision 识别率显著最佳。
    let renderLongEdgePixels: CGFloat

    init(maxPages: Int = 20, renderLongEdgePixels: CGFloat = 2000) {
        self.maxPages = maxPages
        self.renderLongEdgePixels = renderLongEdgePixels
    }

    func extract(
        from data: Data,
        context: ParseRequestContext,
        logger: TraceLogging
    ) async throws -> PDFExtractionResult {
        guard !data.isEmpty, let document = PDFDocument(data: data) else {
            logger.log(LogEvent(
                timestamp: .now,
                level: "error",
                traceID: context.traceID,
                parseRequestID: context.parseRequestID,
                projectID: nil,
                sourceType: .pdf,
                stage: "pdf_extraction",
                decision: "failure",
                reason: "pdf_open_failed",
                durationMS: nil,
                metadata: ["bytes": "\(data.count)"]
            ))
            throw PatternImportFailure.invalidResponse("pdf_open_failed")
        }

        let title = documentTitle(from: document)
        let totalPageCount = document.pageCount
        let effectivePageCount = min(totalPageCount, maxPages)
        let truncated = totalPageCount > maxPages

        if truncated {
            logger.log(LogEvent(
                timestamp: .now,
                level: "warn",
                traceID: context.traceID,
                parseRequestID: context.parseRequestID,
                projectID: nil,
                sourceType: .pdf,
                stage: "pdf_extraction",
                decision: "truncated",
                reason: "page_limit_exceeded",
                durationMS: nil,
                metadata: [
                    "totalPages": "\(totalPageCount)",
                    "processedPages": "\(effectivePageCount)",
                    "maxPages": "\(maxPages)"
                ]
            ))
        }

        var perPageTexts: [String] = []
        var perPageStats: [PDFPageStats] = []

        for pageIndex in 0..<effectivePageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            let started = Date()
            let textLayer = TextNormalizer.normalizePreservingParagraphs(page.string ?? "")
            let rendered = renderPage(page)
            let ocrLines = try await recognizeText(in: rendered?.cgImage)
            let ocrMerged = mergeWithTextLayer(textLayer: textLayer, ocrLines: ocrLines)
            let pageBody = combinedPageText(textLayer: textLayer, ocrTextBlock: ocrMerged)
            perPageTexts.append(pageBody)
            let stats = PDFPageStats(
                pageIndex: pageIndex,
                textLayerCharacterCount: textLayer.count,
                ocrCharacterCount: ocrLines.joined(separator: "\n").count,
                ocrObservationCount: ocrLines.count,
                renderedImageBytes: rendered?.pngBytes ?? 0
            )
            perPageStats.append(stats)
            let duration = Int(Date().timeIntervalSince(started) * 1000)
            logger.log(LogEvent(
                timestamp: .now,
                level: "debug",
                traceID: context.traceID,
                parseRequestID: context.parseRequestID,
                projectID: nil,
                sourceType: .pdf,
                stage: "pdf_extraction",
                decision: "page_processed",
                reason: "ocr_complete",
                durationMS: duration,
                metadata: [
                    "pageIndex": "\(pageIndex)",
                    "textLayerChars": "\(stats.textLayerCharacterCount)",
                    "ocrChars": "\(stats.ocrCharacterCount)",
                    "ocrObservations": "\(stats.ocrObservationCount)",
                    "renderedBytes": "\(stats.renderedImageBytes)"
                ]
            ))
        }

        // 页间用 "\n\n" 分隔；不加 "-- Page N --" 之类人造结构，
        // 防止 LLM 误把人造分段当作 Pattern 标题结构。
        let finalText = perPageTexts
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")

        guard !finalText.isEmpty else {
            logger.log(LogEvent(
                timestamp: .now,
                level: "error",
                traceID: context.traceID,
                parseRequestID: context.parseRequestID,
                projectID: nil,
                sourceType: .pdf,
                stage: "pdf_extraction",
                decision: "empty",
                reason: "no_extractable_text",
                durationMS: nil,
                metadata: ["pageCount": "\(effectivePageCount)"]
            ))
            throw PatternImportFailure.emptyExtraction
        }

        logger.log(LogEvent(
            timestamp: .now,
            level: "debug",
            traceID: context.traceID,
            parseRequestID: context.parseRequestID,
            projectID: nil,
            sourceType: .pdf,
            stage: "pdf_extraction",
            decision: "success",
            reason: "produced_final_text",
            durationMS: nil,
            metadata: [
                "pageCount": "\(effectivePageCount)",
                "totalPageCount": "\(totalPageCount)",
                "finalTextLength": "\(finalText.count)",
                "title": title ?? ""
            ]
        ))

        return PDFExtractionResult(
            title: title,
            finalText: finalText,
            perPageStats: perPageStats,
            truncated: truncated
        )
    }

    // MARK: - Private helpers

    private func documentTitle(from document: PDFDocument) -> String? {
        guard let attrs = document.documentAttributes,
              let raw = attrs[PDFDocumentAttribute.titleAttribute] as? String else {
            return nil
        }
        let normalized = TextNormalizer.normalize(raw)
        return normalized.isEmpty ? nil : normalized
    }

    private struct RenderedPage {
        let cgImage: CGImage
        let pngBytes: Int
    }

    private func renderPage(_ page: PDFPage) -> RenderedPage? {
#if canImport(UIKit)
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let longEdge = max(bounds.width, bounds.height)
        let scale = renderLongEdgePixels / longEdge
        let renderSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: renderSize, format: format)
        let image = renderer.image { ctx in
            let context = ctx.cgContext
            context.setFillColor(UIColor.white.cgColor)
            context.fill(CGRect(origin: .zero, size: renderSize))
            context.saveGState()
            // PDFKit 坐标原点左下，CoreGraphics 也是；但 page.draw 期望当前上下文变换已翻转。
            // UIGraphicsImageRenderer 的上下文原点在左上（Y 向下）——需要翻转。
            context.translateBy(x: 0, y: renderSize.height)
            context.scaleBy(x: scale, y: -scale)
            page.draw(with: .mediaBox, to: context)
            context.restoreGState()
        }
        guard let cgImage = image.cgImage else { return nil }
        let pngBytes = image.pngData()?.count ?? 0
        return RenderedPage(cgImage: cgImage, pngBytes: pngBytes)
#else
        return nil
#endif
    }

    /// 对单页渲染图做 Apple Vision 本地 OCR，并按几何位置重建阅读顺序：
    /// - 按 boundingBox.midY 用 ε=0.02 聚类成行簇（同一视觉行）
    /// - 簇内按 minX 升序（从左到右）
    /// - 簇间按代表 Y 降序（页面上方在前）
    ///
    /// Vision 原生数组顺序对单列简单版面通常 OK，但多列或左文右图版面会乱序；
    /// 此步骤是应对后者的必要保险。
    private func recognizeText(in cgImage: CGImage?) async throws -> [String] {
        guard let cgImage else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        if #available(iOS 16.0, *) {
            request.automaticallyDetectsLanguage = true
            request.revision = VNRecognizeTextRequestRevision3
        }

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try await Task.detached(priority: .userInitiated) {
            try handler.perform([request])
        }.value

        let observations = (request.results ?? [])
        guard !observations.isEmpty else { return [] }

        struct Line {
            var representativeY: CGFloat
            var entries: [(minX: CGFloat, text: String)]
        }

        let lineYTolerance: CGFloat = 0.02
        var lines: [Line] = []
        for obs in observations {
            guard let candidate = obs.topCandidates(1).first else { continue }
            let trimmed = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let midY = obs.boundingBox.midY
            let minX = obs.boundingBox.minX
            if let lineIdx = lines.firstIndex(where: { abs($0.representativeY - midY) <= lineYTolerance }) {
                lines[lineIdx].entries.append((minX: minX, text: trimmed))
                // 用加权平均更新 representativeY（柔性更新，防止簇心漂移过大）
                let count = CGFloat(lines[lineIdx].entries.count)
                lines[lineIdx].representativeY =
                    ((lines[lineIdx].representativeY * (count - 1)) + midY) / count
            } else {
                lines.append(Line(representativeY: midY, entries: [(minX: minX, text: trimmed)]))
            }
        }

        // 簇间按 Y 从大到小（页面上方在前，因为 Vision 单位坐标原点左下）
        lines.sort { $0.representativeY > $1.representativeY }
        // 簇内按 minX 从小到大
        return lines.map { line in
            line.entries
                .sorted { $0.minX < $1.minX }
                .map(\.text)
                .joined(separator: " ")
        }
    }

    /// 合并 OCR 结果与文字层：去除与 textLayer 语义重复的 OCR 行。
    ///
    /// 采用 **token-set 重叠度** 而非字符串包含：因为 OCR 经常对同一段文字
    /// 产生轻微差异（多/缺标点、0↔© 等字形混淆、额外前缀如 "Lf"），
    /// 严格字符串包含会漏判大量近似重复。
    ///
    /// 规则：若 OCR 某行去停用符后的 tokens 中有 ≥ `overlapThreshold` 比例
    /// 已出现在 textLayer 的 token 集合里，则判定为重复丢弃。
    /// 额外约束：line 必须至少有 3 个有效 token 才允许被判定为重复
    /// （短行如 "Ch 21" 容易被泛滥的通用词汇意外匹配）。
    private func mergeWithTextLayer(textLayer: String, ocrLines: [String]) -> [String] {
        guard !textLayer.isEmpty else { return deduplicateAdjacent(ocrLines) }
        let textLayerTokens = tokenSet(of: textLayer)
        let textLayerCanonical = canonicalize(textLayer)
        var result: [String] = []
        for line in ocrLines {
            let canonical = canonicalize(line)
            guard !canonical.isEmpty else { continue }

            // 精确子串命中：最强的重复证据。
            if textLayerCanonical.contains(canonical) {
                continue
            }

            // Token-set 重叠：对多数 OCR 近似重复有效。
            let lineTokens = tokenize(line)
            if lineTokens.count >= 3 {
                let overlapCount = lineTokens.filter { textLayerTokens.contains($0) }.count
                let ratio = Double(overlapCount) / Double(lineTokens.count)
                if ratio >= 0.75 {
                    continue
                }
            }
            result.append(line)
        }
        return deduplicateAdjacent(result)
    }

    /// 相邻 OCR 行完全等价时去重（常见于页头页脚被 OCR 识别多次）。
    private func deduplicateAdjacent(_ lines: [String]) -> [String] {
        var result: [String] = []
        var previousCanonical: String?
        for line in lines {
            let c = canonicalize(line)
            if c.isEmpty { continue }
            if c == previousCanonical { continue }
            result.append(line)
            previousCanonical = c
        }
        return result
    }

    private func canonicalize(_ s: String) -> String {
        let lowered = s.lowercased()
        let collapsed = lowered.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
        return collapsed.trimmingCharacters(in: .whitespaces)
    }

    /// 把字符串拆成 token：小写、按非字母数字字符切分、去掉长度 < 2 的短 token。
    private func tokenize(_ s: String) -> [String] {
        s.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 }
    }

    private func tokenSet(of s: String) -> Set<String> {
        Set(tokenize(s))
    }

    private func combinedPageText(textLayer: String, ocrTextBlock: [String]) -> String {
        var parts: [String] = []
        if !textLayer.isEmpty { parts.append(textLayer) }
        if !ocrTextBlock.isEmpty {
            parts.append(ocrTextBlock.joined(separator: "\n"))
        }
        return parts.joined(separator: "\n")
    }
}
