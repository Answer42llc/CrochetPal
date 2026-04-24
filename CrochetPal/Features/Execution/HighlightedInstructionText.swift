import SwiftUI

/// Renders `rawInstruction` with the phrase that produced the current atomic action
/// painted in an accent color, so the user can see which part of the original text
/// corresponds to the step they are on.
///
/// The naive approach — `AttributedString.range(of: currentAction.sourceText)` — fails
/// when a short `sourceText` like `"2dc"` or `"ch3"` appears multiple times in the raw
/// instruction: it always hits the first occurrence, so the highlight gets stuck at
/// the top of the round even after the user has stepped past it.
///
/// To fix that, we walk the round's actions in sequence and maintain a cursor inside
/// `rawInstruction`. Each action's highlight is searched **from the cursor forward**,
/// so occurrences already "consumed" by earlier actions are skipped. Consecutive
/// actions that share the same `sourceText` (e.g., all iterations of a repeat, which
/// carry the repeat body's sourceText — see `CrochetIRCompiler`) reuse the same range
/// without advancing the cursor. This makes the highlight advance monotonically
/// through the instruction as the user steps through the round.
struct HighlightedInstructionText: View {
    let rawInstruction: String
    let actions: [AtomicAction]
    let currentActionID: UUID?

    var body: some View {
        Text(attributed)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }

    private var attributed: AttributedString {
        var string = AttributedString(rawInstruction)
        let ordered = actions.sorted { $0.sequenceIndex < $1.sequenceIndex }
        guard let currentActionID,
              let nsRange = HighlightRangeResolver.resolveNSRange(
                  currentActionID: currentActionID,
                  orderedActions: ordered,
                  rawInstruction: rawInstruction
              ),
              let range = Range(nsRange, in: string) else {
            return string
        }
        string[range].backgroundColor = .yellow.opacity(0.35)
        string[range].foregroundColor = .primary
        return string
    }
}

/// Pure logic for mapping an atomic action to a range inside `rawInstruction`.
///
/// Walks actions in sequence order, maintaining a cursor in the raw string. Each
/// action's `sourceText` is searched **from the cursor forward** so an ambiguous
/// short phrase (e.g., `"2dc"`) naturally advances through its multiple occurrences
/// as the user steps through the round. Consecutive actions that share the same
/// `sourceText` reuse the same range (e.g., all stitches in a repeat body, which
/// the compiler pins to the repeat's structural phrase).
///
/// Operates on `NSRange` / `String` so the logic is independent of `AttributedString`
/// and trivially unit-testable. The view bridges the result back into
/// `AttributedString.Index` via `Range(_:in:)`.
enum HighlightRangeResolver {
    static func resolveNSRange(
        currentActionID: UUID,
        orderedActions: [AtomicAction],
        rawInstruction: String
    ) -> NSRange? {
        let ns = rawInstruction as NSString
        var lastSourceText: String?
        var lastRange: NSRange?
        // A "pinned group" is a run of ≥2 consecutive actions sharing the same
        // sourceText — typical of a repeat body whose compiler-level sourceText
        // covers every iteration. When we transition out of such a group, the
        // new action is logically AFTER the group (forward-first). When the
        // previous range was just a singleton, the new action may be a child
        // nested inside it (inside-first).
        var pinnedRunLength: Int = 0

        for action in orderedActions {
            guard let sourceText = action.sourceText, !sourceText.isEmpty else {
                if action.id == currentActionID {
                    return nil
                }
                continue
            }

            let resolvedRange: NSRange?
            if sourceText == lastSourceText, let lastRange {
                resolvedRange = lastRange
                pinnedRunLength += 1
            } else {
                let preferForward = pinnedRunLength >= 2
                resolvedRange = findRange(
                    sourceText: sourceText,
                    in: ns,
                    relativeTo: lastRange,
                    preferForward: preferForward
                )
                pinnedRunLength = 1
            }

            if action.id == currentActionID {
                return resolvedRange
            }

            if let resolvedRange {
                lastSourceText = sourceText
                lastRange = resolvedRange
            }
        }

        return nil
    }

    /// Two-phase search relative to the previous highlight range. Priority depends
    /// on `preferForward`:
    ///
    /// - `preferForward = true` — we just exited a pinned group (e.g., a repeat
    ///   body). The next action is most likely AFTER the group, so try the tail
    ///   first. Falling back to inside handles rare cases where the next action
    ///   is actually nested inside the previous phrase.
    /// - `preferForward = false` — the previous range was a single action (often
    ///   a verbose annotation covering the next action's short phrase as a
    ///   substring). Try inside first so a short child like `"ch3"` resolves
    ///   within the parent's `(2dc+ch3)`, not at the next occurrence of `"ch3"`
    ///   much later in the instruction.
    ///
    /// Global search is the final catch-all: even when both tiers miss (e.g.,
    /// the LLM paraphrased the sourceText or emitted a substring that truly
    /// appears only before the previous range), we still show *something*.
    private static func findRange(
        sourceText: String,
        in ns: NSString,
        relativeTo lastRange: NSRange?,
        preferForward: Bool
    ) -> NSRange? {
        if let lastRange {
            let insideRange = { ns.range(of: sourceText, options: [], range: lastRange) }
            let forwardRange: () -> NSRange = {
                let tailStart = lastRange.location + lastRange.length
                guard tailStart < ns.length else { return NSRange(location: NSNotFound, length: 0) }
                return ns.range(
                    of: sourceText,
                    options: [],
                    range: NSRange(location: tailStart, length: ns.length - tailStart)
                )
            }

            let first = preferForward ? forwardRange() : insideRange()
            if first.location != NSNotFound { return first }
            let second = preferForward ? insideRange() : forwardRange()
            if second.location != NSNotFound { return second }
        }

        let global = ns.range(of: sourceText)
        return global.location == NSNotFound ? nil : global
    }
}
