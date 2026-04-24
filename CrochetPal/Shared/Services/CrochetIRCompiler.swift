import Foundation

struct CrochetIRCompiler {
    func expand(
        _ block: CrochetIRInstructionBlock,
        choices: [String: String] = [:]
    ) throws -> CrochetIRExpansion {
        let expanded = try expand(block: block.body, choices: choices, inheritedRepeatSourceText: nil)
        let atomicActions = try expanded.actions.enumerated().map { index, draft in
            try makeAtomicAction(from: draft, sequenceIndex: index)
        }
        let producedStitchCount = atomicActions.reduce(0) { $0 + $1.producedStitches }
        var warnings = expanded.warnings

        if let expected = block.expectedProducedStitches,
           expected != producedStitchCount {
            warnings.append(CrochetIRExpansionWarning(
                code: "atomization_target_stitch_count_mismatch",
                message: "Expected \(expected) produced stitches, but expanded to \(producedStitchCount).",
                sourceText: block.sourceText
            ))
        }

        return CrochetIRExpansion(
            atomicActions: atomicActions,
            producedStitchCount: producedStitchCount,
            warnings: warnings
        )
    }

    func validate(_ block: CrochetIRInstructionBlock) -> CrochetIRValidationReport {
        var issues: [CrochetIRValidationIssue] = []
        validate(block: block.body, issues: &issues)
        validateChoiceIDConsistency(block: block.body, issues: &issues)

        if !issues.contains(where: { $0.severity == .error }) {
            do {
                _ = try expand(block)
            } catch {
                issues.append(CrochetIRValidationIssue(
                    severity: .error,
                    code: "ir_expansion_failed",
                    message: String(describing: error),
                    sourceText: block.sourceText
                ))
            }
        }

        return CrochetIRValidationReport(issues: issues)
    }

    // MARK: - Expansion

    private func expand(
        block: CrochetIRBlock,
        choices: [String: String],
        inheritedRepeatSourceText: String?
    ) throws -> (actions: [CrochetIRActionDraft], warnings: [CrochetIRExpansionWarning]) {
        var actions: [CrochetIRActionDraft] = []
        var warnings: [CrochetIRExpansionWarning] = []

        for statement in block.statements {
            let result = try expand(
                statement: statement,
                choices: choices,
                inheritedRepeatSourceText: inheritedRepeatSourceText
            )
            actions.append(contentsOf: result.actions)
            warnings.append(contentsOf: result.warnings)
        }

        return (actions, warnings)
    }

    /// When `inheritedRepeatSourceText` is non-nil, we are expanding inside a repeat whose
    /// body (or a further-outer body) exposed a structural sourceText — use that as the
    /// highlight anchor for every action instead of the leaf statement's finer-grained
    /// sourceText. This keeps the UI highlight stable on a unique phrase (e.g.
    /// `"(2dc, ch3, 2dc) in each corner as you go"`) throughout all iterations, avoiding
    /// `AttributedString.range(of:)` hitting the first occurrence of an ambiguous short
    /// string like `"2dc"` that appears multiple times in the raw instruction.
    private func expand(
        statement: CrochetIRStatement,
        choices: [String: String],
        inheritedRepeatSourceText: String?
    ) throws -> (actions: [CrochetIRActionDraft], warnings: [CrochetIRExpansionWarning]) {
        let effectiveSourceText = inheritedRepeatSourceText ?? statement.sourceText
        switch statement.kind {
        case let .operation(operation):
            return (try expand(operation: operation, sourceText: effectiveSourceText), [])
        case let .repeatBlock(repeatBlock):
            return try expand(
                repeatBlock: repeatBlock,
                choices: choices,
                inheritedRepeatSourceText: inheritedRepeatSourceText
            )
        case let .conditional(conditional):
            return try expand(conditional: conditional, choices: choices, sourceText: effectiveSourceText)
        case let .note(note):
            guard note.emitAsAction else { return ([], []) }
            return ([CrochetIRActionDraft(
                semantics: .bookkeeping,
                actionTag: "note",
                stitchTag: nil,
                instruction: note.message,
                producedStitches: 0,
                note: nil,
                sourceText: effectiveSourceText ?? note.sourceText
            )], [])
        }
    }

    private func expand(operation op: CrochetIROperation, sourceText: String?) throws -> [CrochetIRActionDraft] {
        guard op.count > 0 else {
            throw PatternImportFailure.invalidResponse("ir_invalid_operation_count")
        }

        switch op.semantics {
        case .stitchProducing:
            guard let stitch = op.stitch else {
                throw PatternImportFailure.invalidResponse("ir_operation_missing_stitch_for_stitch_producing")
            }
            guard CrochetStitchCatalog.isValidStitchTag(stitch) else {
                throw PatternImportFailure.atomizationFailed("atomization_contains_non_action_type:\(stitch)")
            }
            let perStitch = op.producedStitches ?? CrochetStitchCatalog.defaultProducedStitches(for: stitch)
            var actions = (0..<op.count).map { _ in
                CrochetIRActionDraft(
                    semantics: .stitchProducing,
                    actionTag: op.actionTag,
                    stitchTag: stitch,
                    instruction: op.instruction,
                    producedStitches: perStitch,
                    note: nil,
                    sourceText: sourceText
                )
            }
            apply(note: composedNote(for: op), placement: op.notePlacement, to: &actions)
            return actions

        case .increase:
            guard let stitch = op.stitch else {
                throw PatternImportFailure.invalidResponse("ir_operation_missing_stitch_for_increase")
            }
            guard CrochetStitchCatalog.isValidStitchTag(stitch) else {
                throw PatternImportFailure.atomizationFailed("atomization_contains_non_action_type:\(stitch)")
            }
            // Contract: producedStitches is PER-SINGLE-increase (e.g. 2 for sc inc).
            // "1 sc inc" = 2 sc into same stitch, represented as producedPerInc draft actions
            // each carrying producedStitches=1. For count>1, we emit count * producedPerInc drafts.
            //
            // Safety net: older/confused LLM responses sometimes emit producedStitches as the
            // operation's TOTAL output instead of per-inc. Detect and repair when count>1 and
            // rawProduced is a clean multiple of count that exceeds count (a per-inc value of
            // 1 is impossible for an increase, so rawProduced>count is a reliable signal).
            let rawProduced = op.producedStitches ?? 2
            let producedPerInc: Int = {
                guard op.count > 1, rawProduced > op.count, rawProduced % op.count == 0 else {
                    return rawProduced
                }
                return rawProduced / op.count
            }()
            var actions: [CrochetIRActionDraft] = []
            for _ in 0..<op.count {
                for _ in 0..<producedPerInc {
                    actions.append(CrochetIRActionDraft(
                        semantics: .increase,
                        actionTag: op.actionTag,
                        stitchTag: stitch,
                        instruction: op.instruction,
                        producedStitches: 1,
                        note: nil,
                        sourceText: sourceText
                    ))
                }
            }
            apply(note: composedNote(for: op, defaultNote: "inc"), placement: op.notePlacement, to: &actions)
            return actions

        case .decrease:
            let stitchTag = op.stitch ?? "dec"
            guard CrochetStitchCatalog.isValidStitchTag(stitchTag) else {
                throw PatternImportFailure.atomizationFailed("atomization_contains_non_action_type:\(stitchTag)")
            }
            let perStitch = op.producedStitches ?? CrochetStitchCatalog.defaultProducedStitches(for: stitchTag)
            var actions = (0..<op.count).map { _ in
                CrochetIRActionDraft(
                    semantics: .decrease,
                    actionTag: op.actionTag,
                    stitchTag: stitchTag,
                    instruction: op.instruction,
                    producedStitches: perStitch,
                    note: nil,
                    sourceText: sourceText
                )
            }
            apply(note: composedNote(for: op), placement: op.notePlacement, to: &actions)
            return actions

        case .bookkeeping:
            return [CrochetIRActionDraft(
                semantics: .bookkeeping,
                actionTag: op.actionTag,
                stitchTag: nil,
                instruction: resolvedBookkeepingInstruction(for: op),
                producedStitches: 0,
                note: composedNote(for: op),
                sourceText: sourceText
            )]
        }
    }

    /// Composes the note text, combining the operation's `target` (e.g. "same stitch",
    /// "top of first ch3") with the `note` field. `target` describes WHERE the stitch goes and
    /// is valuable context for the user; we surface it alongside any free-text note.
    private func composedNote(for op: CrochetIROperation, defaultNote: String? = nil) -> String? {
        var components: [String] = []
        if let target = normalized(op.target) {
            components.append(target)
        }
        if let note = normalized(op.note) {
            components.append(note)
        } else if let defaultNote = normalized(defaultNote), components.isEmpty {
            components.append(defaultNote)
        }
        return components.isEmpty ? nil : components.joined(separator: "; ")
    }

    /// Falls back through instruction → humanized actionTag so the UI always has something
    /// readable to show for bookkeeping actions.
    private func resolvedBookkeepingInstruction(for op: CrochetIROperation) -> String {
        if let instruction = AtomicAction.normalizedInstruction(op.instruction) {
            return instruction
        }
        return humanizeActionTag(op.actionTag)
    }

    /// Converts camelCase action tags into title-cased human strings.
    /// "placeMarker" → "Place marker", "joinYarn" → "Join yarn", "turn" → "Turn".
    private func humanizeActionTag(_ tag: String) -> String {
        guard !tag.isEmpty else { return "action" }
        var result = ""
        for (index, character) in tag.enumerated() {
            if index == 0 {
                result.append(character.uppercased())
            } else if character.isUppercase {
                result.append(" ")
                result.append(character.lowercased())
            } else {
                result.append(character)
            }
        }
        return result
    }

    private func expand(
        repeatBlock: CrochetIRRepeatBlock,
        choices: [String: String],
        inheritedRepeatSourceText: String?
    ) throws -> (actions: [CrochetIRActionDraft], warnings: [CrochetIRExpansionWarning]) {
        guard repeatBlock.times > 0 else {
            throw PatternImportFailure.invalidResponse("ir_invalid_repeat_times")
        }
        guard !repeatBlock.body.statements.isEmpty else {
            throw PatternImportFailure.invalidResponse("ir_empty_repeat_body")
        }

        var actions: [CrochetIRActionDraft] = []
        var warnings: [CrochetIRExpansionWarning] = []

        // Prefer the repeat body's own sourceText; fall back to whatever outer repeat
        // already inherited. Nested repeats therefore always anchor to the nearest
        // non-nil structural phrase.
        let innerInherited = repeatBlock.body.sourceText ?? inheritedRepeatSourceText

        for _ in 0..<repeatBlock.times {
            let result = try expand(
                block: repeatBlock.body,
                choices: choices,
                inheritedRepeatSourceText: innerInherited
            )
            actions.append(contentsOf: result.actions)
            warnings.append(contentsOf: result.warnings)
        }

        return (actions, warnings)
    }

    private func expand(
        conditional: CrochetIRConditional,
        choices: [String: String],
        sourceText: String?
    ) throws -> (actions: [CrochetIRActionDraft], warnings: [CrochetIRExpansionWarning]) {
        let selectedValue = choices[conditional.choiceID] ?? conditional.defaultBranchValue
        guard let selectedValue else {
            return ([CrochetIRActionDraft(
                semantics: .bookkeeping,
                actionTag: "conditionalPrompt",
                stitchTag: nil,
                instruction: conditional.question,
                producedStitches: 0,
                note: nil,
                sourceText: sourceText
            )], [CrochetIRExpansionWarning(
                code: "ir_missing_choice",
                message: "A choice is required for \(conditional.choiceID).",
                sourceText: nil
            )])
        }
        guard let branch = conditional.branches.first(where: { $0.value == selectedValue }) else {
            return ([CrochetIRActionDraft(
                semantics: .bookkeeping,
                actionTag: "conditionalPrompt",
                stitchTag: nil,
                instruction: conditional.question,
                producedStitches: 0,
                note: nil,
                sourceText: sourceText
            )], [CrochetIRExpansionWarning(
                code: "ir_unknown_choice",
                message: "No branch matched choice value \(selectedValue).",
                sourceText: nil
            )])
        }

        var out: [CrochetIRActionDraft] = []
        var warnings: [CrochetIRExpansionWarning] = []

        let branchResult = try expand(block: branch.body, choices: choices, inheritedRepeatSourceText: nil)
        out.append(contentsOf: branchResult.actions)
        warnings.append(contentsOf: branchResult.warnings)

        if let commonBody = conditional.commonBody {
            let commonResult = try expand(block: commonBody, choices: choices, inheritedRepeatSourceText: nil)
            out.append(contentsOf: commonResult.actions)
            warnings.append(contentsOf: commonResult.warnings)
        }

        return (out, warnings)
    }

    // MARK: - Validation

    private func validate(block: CrochetIRBlock, issues: inout [CrochetIRValidationIssue]) {
        for statement in block.statements {
            validate(statement: statement, issues: &issues)
        }
    }

    private func validate(statement: CrochetIRStatement, issues: inout [CrochetIRValidationIssue]) {
        switch statement.kind {
        case let .operation(op):
            validate(operation: op, sourceText: statement.sourceText, issues: &issues)
        case let .repeatBlock(rb):
            validate(repeatBlock: rb, sourceText: statement.sourceText, issues: &issues)
        case let .conditional(c):
            validate(conditional: c, issues: &issues)
        case let .note(note):
            if note.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(CrochetIRValidationIssue(
                    severity: .warning,
                    code: "ir_empty_note",
                    message: "Note is empty.",
                    sourceText: note.sourceText
                ))
            }
        }
    }

    private func validate(
        operation op: CrochetIROperation,
        sourceText: String?,
        issues: inout [CrochetIRValidationIssue]
    ) {
        if op.count <= 0 {
            issues.append(CrochetIRValidationIssue(
                severity: .error,
                code: "ir_invalid_operation_count",
                message: "Operation count must be positive.",
                sourceText: sourceText
            ))
        }
        if normalized(op.actionTag) == nil {
            issues.append(CrochetIRValidationIssue(
                severity: .error,
                code: "ir_operation_missing_action_tag",
                message: "Operation must define a non-empty actionTag.",
                sourceText: sourceText
            ))
        } else if !isValidActionTag(op.actionTag) {
            issues.append(CrochetIRValidationIssue(
                severity: .error,
                code: "ir_operation_invalid_action_tag",
                message: "actionTag must be camelCase letters or digits (got \(op.actionTag)).",
                sourceText: sourceText
            ))
        }

        switch op.semantics {
        case .stitchProducing, .increase, .decrease:
            if op.stitch == nil {
                issues.append(CrochetIRValidationIssue(
                    severity: .error,
                    code: "ir_operation_semantics_mismatch",
                    message: "Operation with semantics \(op.semantics.rawValue) requires a stitch tag.",
                    sourceText: sourceText
                ))
            } else if let stitch = op.stitch, !CrochetStitchCatalog.isValidStitchTag(stitch) {
                // Descriptors/meta (blo, flo, skip, ...) cannot stand in for a stitch.
                // Unknown tags (pattern-specific abbreviations) ARE allowed.
                issues.append(CrochetIRValidationIssue(
                    severity: .error,
                    code: "ir_contains_non_action_type",
                    message: "\(stitch) is a descriptor/meta tag, not a stitch.",
                    sourceText: sourceText
                ))
            }
            if op.semantics == .increase,
               op.count > 1,
               let produced = op.producedStitches,
               produced > op.count,
               produced % op.count == 0 {
                // producedStitches is defined as PER-SINGLE-increase. When it looks like a
                // clean multiple of count that exceeds 2-per-inc, the LLM most likely emitted
                // the operation's TOTAL output instead. The compiler will auto-repair on expand,
                // but we surface a warning so the miscalibration is observable in traces.
                issues.append(CrochetIRValidationIssue(
                    severity: .warning,
                    code: "ir_increase_produced_stitches_looks_like_total",
                    message: "producedStitches (\(produced)) looks like the total output for count \(op.count); expected a per-increase value. Compiler will normalize to \(produced / op.count).",
                    sourceText: sourceText
                ))
            }
        case .bookkeeping:
            // bookkeeping operations MAY carry an optional stitch tag when the action has
            // a canonical stitch-like name — e.g. `mr` (magic ring), `fo` (fasten off),
            // `slst` used as a join. It's just informational for the UI; compiler treats
            // bookkeeping as stitchless regardless.
            break
        }
    }

    private func validate(
        repeatBlock rb: CrochetIRRepeatBlock,
        sourceText: String?,
        issues: inout [CrochetIRValidationIssue]
    ) {
        if rb.times <= 0 {
            issues.append(CrochetIRValidationIssue(
                severity: .error,
                code: "ir_invalid_repeat_times",
                message: "Repeat times must be positive.",
                sourceText: sourceText
            ))
        }
        if rb.body.statements.isEmpty {
            issues.append(CrochetIRValidationIssue(
                severity: .error,
                code: "ir_empty_repeat_body",
                message: "Repeat body must not be empty.",
                sourceText: sourceText
            ))
        }

        if detectIterationExceptionSmell(
            sourceText: sourceText,
            block: rb.body,
            normalizationNote: rb.normalizationNote
        ) {
            issues.append(CrochetIRValidationIssue(
                severity: .error,
                code: "ir_iteration_specific_exception_not_normalized",
                message: "Instruction contains iteration-specific exception (omit final / instead / on the last repeat / ...). The canonical IR must normalize this into a homogeneous repeatBlock plus flat statements outside the repeat.",
                sourceText: sourceText
            ))
        }

        validate(block: rb.body, issues: &issues)
    }

    private func validate(
        conditional: CrochetIRConditional,
        issues: inout [CrochetIRValidationIssue]
    ) {
        if conditional.branches.isEmpty {
            issues.append(CrochetIRValidationIssue(
                severity: .error,
                code: "ir_empty_conditional_branches",
                message: "Conditional block must define at least one branch.",
                sourceText: nil
            ))
        }
        for branch in conditional.branches {
            validate(block: branch.body, issues: &issues)
        }
        if let commonBody = conditional.commonBody {
            validate(block: commonBody, issues: &issues)
        }
    }

    /// Cross-statement check: if two or more `CrochetIRConditional`s share the same `choiceID`,
    /// they must expose identical branch values and defaults so a single user input drives all
    /// of them (supports "if you used one" kind of back-references).
    private func validateChoiceIDConsistency(
        block: CrochetIRBlock,
        issues: inout [CrochetIRValidationIssue]
    ) {
        var groups: [String: [CrochetIRConditional]] = [:]
        collectConditionals(block: block, into: &groups)

        for (choiceID, conditionals) in groups where conditionals.count > 1 {
            let branchValues = conditionals.map { Set($0.branches.map(\.value)) }
            let defaults = Set(conditionals.map { $0.defaultBranchValue ?? "" })
            let allBranchesMatch = branchValues.dropFirst().allSatisfy { $0 == branchValues[0] }
            if !allBranchesMatch || defaults.count > 1 {
                issues.append(CrochetIRValidationIssue(
                    severity: .error,
                    code: "ir_conditional_choice_id_mismatch",
                    message: "Conditionals sharing choiceID '\(choiceID)' must expose identical branches and defaultBranchValue.",
                    sourceText: nil
                ))
            }
        }
    }

    private func collectConditionals(
        block: CrochetIRBlock,
        into groups: inout [String: [CrochetIRConditional]]
    ) {
        for statement in block.statements {
            switch statement.kind {
            case let .conditional(c):
                groups[c.choiceID, default: []].append(c)
                for branch in c.branches {
                    collectConditionals(block: branch.body, into: &groups)
                }
                if let commonBody = c.commonBody {
                    collectConditionals(block: commonBody, into: &groups)
                }
            case let .repeatBlock(rb):
                collectConditionals(block: rb.body, into: &groups)
            case .operation, .note:
                break
            }
        }
    }

    // MARK: - Iteration exception heuristic

    /// The LLM sometimes forgets to normalize "repeat 3 times, omit the final X" into
    /// "repeat 2 times + flat final iteration". We scan sourceText fields for trigger phrases;
    /// if any appears AND the IR does not carry an explicit `normalizationNote` showing the
    /// LLM was aware of the exception, we return a repairable error.
    private func detectIterationExceptionSmell(
        sourceText: String?,
        block: CrochetIRBlock,
        normalizationNote: String?
    ) -> Bool {
        // If the LLM explicitly acknowledged normalization, assume it handled it correctly.
        if let note = normalized(normalizationNote), !note.isEmpty {
            return false
        }

        let phrases = [
            "omit the final", "omit final",
            ", instead", ". instead",
            "on the final", "on the last repeat",
            "on the first repeat", "on the nth repeat",
            "except on", "but on the last", "but on the first"
        ]

        let candidateTexts: [String?] = [sourceText, block.sourceText]
            + block.statements.map { $0.sourceText }
        let haystack = candidateTexts.compactMap { $0 }.joined(separator: " ").lowercased()
        return phrases.contains(where: haystack.contains)
    }

    // MARK: - Helpers

    private func isValidActionTag(_ tag: String) -> Bool {
        // actionTag is intentionally open — we only reject obvious junk (empty, whitespace,
        // non-identifier characters). Allow the common identifier alphabets: letters,
        // digits, underscore, hyphen. This matches both camelCase (`placeMarker`),
        // snake_case (`sl_st` — which is `StitchActionType.slSt.rawValue`), kebab-case
        // (`cap-stitch`), and all-caps abbreviations (`FPdc`, `CS`).
        guard !tag.isEmpty, let first = tag.first, first.isLetter else { return false }
        return tag.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
    }

    private func apply(
        note: String?,
        placement: AtomizedNotePlacement,
        to actions: inout [CrochetIRActionDraft]
    ) {
        guard let note = normalized(note), !actions.isEmpty else { return }
        switch placement {
        case .first:
            actions[0].note = note
        case .last:
            actions[actions.count - 1].note = note
        case .all:
            for index in actions.indices {
                actions[index].note = note
            }
        }
    }

    private func makeAtomicAction(
        from draft: CrochetIRActionDraft,
        sequenceIndex: Int
    ) throws -> AtomicAction {
        if let stitch = draft.stitchTag, !CrochetStitchCatalog.isValidStitchTag(stitch) {
            throw PatternImportFailure.atomizationFailed("atomization_contains_non_action_type:\(stitch)")
        }
        return AtomicAction(
            semantics: draft.semantics,
            actionTag: draft.actionTag,
            stitchTag: draft.stitchTag,
            instruction: AtomicAction.normalizedInstruction(draft.instruction),
            producedStitches: draft.producedStitches,
            note: normalized(draft.note),
            sourceText: normalized(draft.sourceText),
            sequenceIndex: sequenceIndex
        )
    }

    private func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct CrochetIRActionDraft: Hashable {
    var semantics: CrochetIROperationSemantics
    var actionTag: String
    var stitchTag: String?
    var instruction: String?
    var producedStitches: Int
    var note: String?
    var sourceText: String?
}
