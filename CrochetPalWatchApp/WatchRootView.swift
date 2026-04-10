import Combine
import SwiftUI

@MainActor
final class WatchCompanionStore: ObservableObject {
    @Published var snapshot: ProjectSnapshot?

    private let syncCoordinator: WatchSyncCoordinator
    private let motionInput: WatchMotionInput
    private var cancellables: Set<AnyCancellable> = []

    init(syncCoordinator: WatchSyncCoordinator, motionInput: WatchMotionInput) {
        self.syncCoordinator = syncCoordinator
        self.motionInput = motionInput
        self.snapshot = syncCoordinator.currentSnapshot

        syncCoordinator.$currentSnapshot
            .receive(on: DispatchQueue.main)
            .assign(to: &$snapshot)

        motionInput.onCommand = { [weak self] command in
            Task { @MainActor in
                await self?.send(command, source: .motion)
            }
        }

        Task {
            await syncCoordinator.requestSnapshot()
        }
        motionInput.start()
    }

    static func make() -> WatchCompanionStore {
        WatchCompanionStore(
            syncCoordinator: WatchSyncCoordinator(),
            motionInput: WatchMotionInput()
        )
    }

    func send(_ command: ExecutionCommand, source: ExecutionCommandSource) async {
        guard let projectID = snapshot?.projectID else { return }
        await syncCoordinator.send(command: command, projectID: projectID, source: source)
    }
}

struct WatchRootView: View {
    @EnvironmentObject private var store: WatchCompanionStore

    var body: some View {
        Group {
            if let snapshot = store.snapshot {
                VStack(spacing: 12) {
                    Text(snapshot.roundTitle)
                        .font(.headline)
                    Text(snapshot.actionTitle)
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                    Text(snapshot.actionHint)
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                    if let actionNote = snapshot.actionNote, !actionNote.isEmpty {
                        Text(actionNote)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    if let statusMessage = snapshot.statusMessage, snapshot.executionState != .ready {
                        Text(statusMessage)
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .multilineTextAlignment(.center)
                    }
                    Text("\(snapshot.stitchProgress)/\(snapshot.targetStitches ?? 0)")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack {
                        Button {
                            Task { await store.send(.undo, source: .watchButton) }
                        } label: {
                            Image(systemName: "arrow.uturn.backward.circle.fill")
                        }

                        Button {
                            Task { await store.send(.forward, source: .watchButton) }
                        } label: {
                            Image(systemName: "arrow.right.circle.fill")
                        }
                        .disabled(!snapshot.canAdvance)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
            } else {
                ContentUnavailableView("Open CrochetPal on iPhone", systemImage: "applewatch")
            }
        }
    }
}
