import SwiftUI

struct RoundEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var container: AppContainer

    let projectID: UUID
    let partID: UUID
    let round: PatternRound

    @State private var title: String
    @State private var rawInstruction: String
    @State private var summary: String
    @State private var targetStitchCount: String
    @State private var drafts: [RoundActionDraft]

    init(projectID: UUID, partID: UUID, round: PatternRound) {
        self.projectID = projectID
        self.partID = partID
        self.round = round
        _title = State(initialValue: round.title)
        _rawInstruction = State(initialValue: round.rawInstruction)
        _summary = State(initialValue: round.summary)
        _targetStitchCount = State(initialValue: round.targetStitchCount.map(String.init) ?? "")
        _drafts = State(initialValue: RoundEditorView.makeDrafts(from: round.atomicActions))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Round") {
                    TextField("Title", text: $title)
                    TextField("Raw Instruction", text: $rawInstruction, axis: .vertical)
                    TextField("Summary", text: $summary, axis: .vertical)
                    TextField("Target Stitch Count", text: $targetStitchCount)
                        .keyboardType(.numberPad)
                }

                Section("Actions") {
                    ForEach($drafts) { $draft in
                        VStack(alignment: .leading, spacing: 12) {
                            Picker("Type", selection: $draft.type) {
                                ForEach(StitchActionType.allCases.filter { $0 != .skip }) { action in
                                    Text(action.title).tag(action)
                                }
                            }
                            TextField("Instruction", text: $draft.instruction)
                            TextField("Note", text: $draft.note, axis: .vertical)
                            Stepper("Produced Stitches: \(draft.producedStitches)", value: $draft.producedStitches, in: 0...4)
                            Stepper("Count: \(draft.count)", value: $draft.count, in: 1...40)
                            Button("Delete Action", role: .destructive) {
                                drafts.removeAll { $0.id == draft.id }
                            }
                        }
                        .padding(.vertical, 6)
                    }

                    Button("Add Action") {
                        drafts.append(RoundActionDraft(type: .sc, instruction: "SC", producedStitches: 1, note: "", count: 1))
                    }
                }
            }
            .navigationTitle("Edit Round")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        save()
                    }
                }
            }
        }
    }

    private func save() {
        var sequenceIndex = 0
        let atomicActions = drafts.flatMap { draft in
            (0..<draft.count).map { _ in
                defer { sequenceIndex += 1 }
                return AtomicAction(
                    type: draft.type,
                    instruction: AtomicAction.normalizedInstruction(draft.instruction),
                    producedStitches: draft.producedStitches,
                    note: draft.note.isEmpty ? nil : draft.note,
                    sequenceIndex: sequenceIndex
                )
            }
        }

        let updated = PatternRound(
            id: round.id,
            title: title,
            rawInstruction: rawInstruction,
            summary: summary,
            targetStitchCount: Int(targetStitchCount),
            atomizationStatus: .ready,
            atomizationError: nil,
            atomicActions: atomicActions
        )
        container.repository.update(round: updated, in: partID, projectID: projectID)
        dismiss()
    }

    private static func makeDrafts(from atomicActions: [AtomicAction]) -> [RoundActionDraft] {
        guard !atomicActions.isEmpty else {
            return [RoundActionDraft(type: .sc, instruction: "SC", producedStitches: 1, note: "", count: 1)]
        }

        var drafts: [RoundActionDraft] = []
        for action in atomicActions {
            if var last = drafts.last,
               last.type == action.type,
               last.instruction == action.instruction,
               last.producedStitches == action.producedStitches,
               last.note == (action.note ?? "") {
                last.count += 1
                drafts[drafts.count - 1] = last
            } else {
                drafts.append(
                    RoundActionDraft(
                        type: action.type,
                        instruction: action.instruction ?? "",
                        producedStitches: action.producedStitches,
                        note: action.note ?? "",
                        count: 1
                    )
                )
            }
        }
        return drafts
    }
}
