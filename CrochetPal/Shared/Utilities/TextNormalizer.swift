import Foundation

/// 统一的文本规范化工具：对 HTML/PDF/OCR 等来源抽取出的原始文本做统一清洗，
/// 去除换行差异、硬空格、Unicode 变体字符（× → x、智能引号 → 直引号）等。
/// 高复用、低耦合原则：网页、PDF 两条导入管道共享同一实现。
enum TextNormalizer {
    static func normalize(_ text: String) -> String {
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

    /// 保留段落结构的规范化：把 `\r\n` 和单独的 `\n` 转成空格以折叠段落内软换行，
    /// 但保留 `\n\n` 作为段落边界。用于需要保留页/段语义的场景（PDF 合并文本等）。
    static func normalizePreservingParagraphs(_ text: String) -> String {
        var result = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\u{00a0}", with: " ")
            .replacingOccurrences(of: "\u{00d7}", with: "x")
            .replacingOccurrences(of: "\u{2013}", with: "-")
            .replacingOccurrences(of: "\u{2014}", with: "-")
            .replacingOccurrences(of: "\u{2018}", with: "'")
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{201c}", with: "\"")
            .replacingOccurrences(of: "\u{201d}", with: "\"")

        // 把 3+ 个换行压缩成 2 个（保留段落边界语义）。
        result = result.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        // 同一行内的连续空白（不跨行）折叠成单空格。
        result = result.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
