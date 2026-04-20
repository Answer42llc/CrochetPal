import Foundation

struct CrochetIRCompiler {
    func expand(
        _ block: CrochetIRInstructionBlock,
        choices: [String: String] = [:]
    ) throws -> CrochetIRExpansion {
        let expanded = try expand(nodes: block.nodes, choices: choices)
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
        validate(nodes: block.nodes, issues: &issues)

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

    private func expand(
        nodes: [CrochetIRNode],
        choices: [String: String]
    ) throws -> (actions: [CrochetIRActionDraft], warnings: [CrochetIRExpansionWarning]) {
        var actions: [CrochetIRActionDraft] = []
        var warnings: [CrochetIRExpansionWarning] = []

        for node in nodes {
            let result = try expand(node: node, choices: choices)
            actions.append(contentsOf: result.actions)
            warnings.append(contentsOf: result.warnings)
        }

        return (actions, warnings)
    }

    private func expand(
        node: CrochetIRNode,
        choices: [String: String]
    ) throws -> (actions: [CrochetIRActionDraft], warnings: [CrochetIRExpansionWarning]) {
        switch node {
        case let .stitch(stitch):
            return (try expand(stitch: stitch), [])
        case let .repeatBlock(repeatBlock):
            return try expand(repeatBlock: repeatBlock, choices: choices)
        case let .conditional(conditional):
            return try expand(conditional: conditional, choices: choices)
        case let .control(control):
            return (try expand(control: control), [])
        case let .note(note):
            guard note.emitAsAction else {
                return ([], [])
            }
            return ([CrochetIRActionDraft(
                type: .custom,
                instruction: note.message,
                producedStitches: 0,
                note: nil
            )], [])
        case let .ambiguous(ambiguous):
            let instruction = ambiguous.safeInstruction ?? ambiguous.sourceText
            return ([CrochetIRActionDraft(
                type: .custom,
                instruction: instruction,
                producedStitches: 0,
                note: ambiguous.reason
            )], [CrochetIRExpansionWarning(
                code: "ir_ambiguous_source",
                message: ambiguous.reason,
                sourceText: ambiguous.sourceText
            )])
        }
    }

    private func expand(stitch: CrochetIRStitch) throws -> [CrochetIRActionDraft] {
        guard stitch.count > 0 else {
            throw PatternImportFailure.invalidResponse("ir_invalid_stitch_count")
        }
        guard stitch.type.isAtomicActionType else {
            throw PatternImportFailure.atomizationFailed("atomization_contains_non_action_type:\(stitch.type.rawValue)")
        }

        var actions = (0..<stitch.count).map { _ in
            CrochetIRActionDraft(
                type: stitch.type,
                instruction: stitch.instruction,
                producedStitches: stitch.type.resolvedAtomizationProducedStitches(from: stitch.producedStitches),
                note: nil
            )
        }
        apply(note: stitch.note, placement: stitch.notePlacement, to: &actions)
        return actions
    }

    private func expand(
        repeatBlock: CrochetIRRepeat,
        choices: [String: String]
    ) throws -> (actions: [CrochetIRActionDraft], warnings: [CrochetIRExpansionWarning]) {
        guard repeatBlock.times > 0 else {
            throw PatternImportFailure.invalidResponse("ir_invalid_repeat_times")
        }
        guard !repeatBlock.body.isEmpty else {
            throw PatternImportFailure.invalidResponse("ir_empty_repeat_body")
        }

        var actions: [CrochetIRActionDraft] = []
        var warnings: [CrochetIRExpansionWarning] = []

        for iteration in 0..<repeatBlock.times {
            let body = try bodyForRepeatIteration(
                repeatBlock,
                isLastIteration: iteration == repeatBlock.times - 1
            )
            let result = try expand(nodes: body, choices: choices)
            actions.append(contentsOf: result.actions)
            warnings.append(contentsOf: result.warnings)
        }

        return (actions, warnings)
    }

    private func bodyForRepeatIteration(
        _ repeatBlock: CrochetIRRepeat,
        isLastIteration: Bool
    ) throws -> [CrochetIRNode] {
        guard isLastIteration,
              let transform = repeatBlock.lastIterationTransform else {
            return repeatBlock.body
        }
        guard transform.removeTailNodeCount >= 0,
              transform.removeTailNodeCount <= repeatBlock.body.count else {
            throw PatternImportFailure.invalidResponse("ir_invalid_last_iteration_tail_removal")
        }

        let keptCount = repeatBlock.body.count - transform.removeTailNodeCount
        return Array(repeatBlock.body.prefix(keptCount)) + transform.append
    }

    private func expand(
        conditional: CrochetIRConditional,
        choices: [String: String]
    ) throws -> (actions: [CrochetIRActionDraft], warnings: [CrochetIRExpansionWarning]) {
        let selectedValue = choices[conditional.choiceID] ?? conditional.defaultBranchValue
        guard let selectedValue else {
            return ([CrochetIRActionDraft(
                type: .custom,
                instruction: conditional.question,
                producedStitches: 0,
                note: nil
            )], [CrochetIRExpansionWarning(
                code: "ir_missing_choice",
                message: "A choice is required for \(conditional.choiceID).",
                sourceText: conditional.sourceText
            )])
        }
        guard let branch = conditional.branches.first(where: { $0.value == selectedValue }) else {
            return ([CrochetIRActionDraft(
                type: .custom,
                instruction: conditional.question,
                producedStitches: 0,
                note: nil
            )], [CrochetIRExpansionWarning(
                code: "ir_unknown_choice",
                message: "No branch matched choice value \(selectedValue).",
                sourceText: conditional.sourceText
            )])
        }

        return try expand(nodes: branch.nodes + conditional.commonBody, choices: choices)
    }

    private func expand(control: CrochetIRControl) throws -> [CrochetIRActionDraft] {
        let instruction = AtomicAction.normalizedInstruction(control.instruction)

        switch control.kind {
        case .turn:
            return [CrochetIRActionDraft(
                type: .custom,
                instruction: instruction ?? "turn",
                producedStitches: 0,
                note: control.note
            )]
        case .skip:
            return [CrochetIRActionDraft(
                type: .skip,
                instruction: instruction ?? "skip",
                producedStitches: 0,
                note: control.note
            )]
        case .custom:
            guard let instruction else {
                throw PatternImportFailure.invalidResponse("ir_missing_custom_control_instruction")
            }
            return [CrochetIRActionDraft(
                type: .custom,
                instruction: instruction,
                producedStitches: 0,
                note: control.note
            )]
        }
    }

    private func validate(nodes: [CrochetIRNode], issues: inout [CrochetIRValidationIssue]) {
        for node in nodes {
            validate(node: node, issues: &issues)
        }
    }

    private func validate(node: CrochetIRNode, issues: inout [CrochetIRValidationIssue]) {
        switch node {
        case let .stitch(stitch):
            if stitch.count <= 0 {
                issues.append(CrochetIRValidationIssue(
                    severity: .error,
                    code: "ir_invalid_stitch_count",
                    message: "Stitch count must be positive.",
                    sourceText: stitch.sourceText
                ))
            }
            if !stitch.type.isAtomicActionType {
                issues.append(CrochetIRValidationIssue(
                    severity: .error,
                    code: "ir_contains_non_action_type",
                    message: "\(stitch.type.rawValue) is not an atomic action type.",
                    sourceText: stitch.sourceText
                ))
            }
        case let .repeatBlock(repeatBlock):
            if repeatBlock.times <= 0 {
                issues.append(CrochetIRValidationIssue(
                    severity: .error,
                    code: "ir_invalid_repeat_times",
                    message: "Repeat times must be positive.",
                    sourceText: repeatBlock.sourceText
                ))
            }
            if repeatBlock.body.isEmpty {
                issues.append(CrochetIRValidationIssue(
                    severity: .error,
                    code: "ir_empty_repeat_body",
                    message: "Repeat body must not be empty.",
                    sourceText: repeatBlock.sourceText
                ))
            }
            if let transform = repeatBlock.lastIterationTransform,
               transform.removeTailNodeCount < 0 || transform.removeTailNodeCount > repeatBlock.body.count {
                issues.append(CrochetIRValidationIssue(
                    severity: .error,
                    code: "ir_invalid_last_iteration_tail_removal",
                    message: "Last-iteration transform removes more nodes than the repeat body contains.",
                    sourceText: transform.sourceText ?? repeatBlock.sourceText
                ))
            }
            validate(nodes: repeatBlock.body, issues: &issues)
            if let transform = repeatBlock.lastIterationTransform {
                validate(nodes: transform.append, issues: &issues)
            }
        case let .conditional(conditional):
            if conditional.branches.isEmpty {
                issues.append(CrochetIRValidationIssue(
                    severity: .error,
                    code: "ir_empty_conditional_branches",
                    message: "Conditional block must define at least one branch.",
                    sourceText: conditional.sourceText
                ))
            }
            for branch in conditional.branches {
                validate(nodes: branch.nodes, issues: &issues)
            }
            validate(nodes: conditional.commonBody, issues: &issues)
        case let .control(control):
            if control.kind == .custom,
               AtomicAction.normalizedInstruction(control.instruction) == nil {
                issues.append(CrochetIRValidationIssue(
                    severity: .error,
                    code: "ir_missing_custom_control_instruction",
                    message: "Custom control nodes must include an instruction.",
                    sourceText: control.sourceText
                ))
            }
        case let .note(note):
            if note.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(CrochetIRValidationIssue(
                    severity: .warning,
                    code: "ir_empty_note",
                    message: "Note is empty.",
                    sourceText: note.sourceText
                ))
            }
        case let .ambiguous(ambiguous):
            issues.append(CrochetIRValidationIssue(
                severity: .warning,
                code: "ir_ambiguous_source",
                message: ambiguous.reason,
                sourceText: ambiguous.sourceText
            ))
        }
    }

    private func apply(
        note: String?,
        placement: AtomizedNotePlacement,
        to actions: inout [CrochetIRActionDraft]
    ) {
        guard let note = normalized(note), !actions.isEmpty else {
            return
        }

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

    private func makeAtomicAction(from draft: CrochetIRActionDraft, sequenceIndex: Int) throws -> AtomicAction {
        if draft.type == .custom {
            return AtomicAction(
                type: .custom,
                instruction: AtomicAction.normalizedInstruction(draft.instruction),
                producedStitches: draft.producedStitches,
                note: normalized(draft.note),
                sequenceIndex: sequenceIndex
            )
        }

        guard draft.type.isAtomicActionType else {
            throw PatternImportFailure.atomizationFailed("atomization_contains_non_action_type:\(draft.type.rawValue)")
        }

        return AtomicAction(
            type: draft.type,
            instruction: AtomicAction.normalizedInstruction(draft.instruction),
            producedStitches: draft.producedStitches,
            note: normalized(draft.note),
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
    var type: StitchActionType
    var instruction: String?
    var producedStitches: Int
    var note: String?
}
