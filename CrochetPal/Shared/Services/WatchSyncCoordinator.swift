import Combine
import Foundation

#if canImport(WatchConnectivity)
import WatchConnectivity

@MainActor
final class WatchSyncCoordinator: NSObject, ObservableObject {
    @Published private(set) var currentSnapshot: ProjectSnapshot?

    var onCommandReceived: ((UUID, ExecutionCommand, ExecutionCommandSource) -> Void)?
    var requestSnapshotProvider: (() async -> ProjectSnapshot?)?

    private let storage: JSONFileStoring
    private let filename = "watch_snapshot.json"
    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    override init() {
        self.storage = JSONFileStore()
        super.init()
        currentSnapshot = try? storage.load(ProjectSnapshot.self, from: filename)
        activate()
    }

    func activate() {
        guard !Self.isRunningTests else { return }
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func send(command: ExecutionCommand, projectID: UUID, source: ExecutionCommandSource) async {
        guard !Self.isRunningTests else { return }
        guard WCSession.default.isReachable else { return }
        let payload: [String: Any] = [
            "type": "command",
            "command": command.rawValue,
            "projectID": projectID.uuidString,
            "source": source.rawValue
        ]
        try? await sendMessage(payload)
    }

    func push(snapshot: ProjectSnapshot) async {
        currentSnapshot = snapshot
        try? storage.save(snapshot, to: filename)
        guard !Self.isRunningTests else { return }
        let payload = snapshotPayload(snapshot)
        if WCSession.default.isReachable {
            try? await sendMessage(payload)
        } else {
            try? WCSession.default.updateApplicationContext(payload)
        }
    }

    func requestSnapshot() async {
        guard !Self.isRunningTests else { return }
        guard WCSession.default.isReachable else { return }
        try? await sendMessage(["type": "snapshot_request"])
    }

    private func snapshotPayload(_ snapshot: ProjectSnapshot) -> [String: Any] {
        [
            "type": "snapshot",
            "projectID": snapshot.projectID.uuidString,
            "title": snapshot.title,
            "partName": snapshot.partName,
            "roundTitle": snapshot.roundTitle,
            "actionTitle": snapshot.actionTitle,
            "actionHint": snapshot.actionHint,
            "actionNote": snapshot.actionNote ?? "",
            "nextActionTitle": snapshot.nextActionTitle ?? "",
            "stitchProgress": snapshot.stitchProgress,
            "targetStitches": snapshot.targetStitches ?? -1,
            "executionState": snapshot.executionState.rawValue,
            "statusMessage": snapshot.statusMessage ?? "",
            "canAdvance": snapshot.canAdvance,
            "isComplete": snapshot.isComplete,
            "updatedAt": snapshot.updatedAt.timeIntervalSince1970
        ]
    }

    private func makeSnapshot(from payload: [String: Any]) -> ProjectSnapshot? {
        guard
            let projectIDString = payload["projectID"] as? String,
            let projectID = UUID(uuidString: projectIDString),
            let title = payload["title"] as? String,
            let partName = payload["partName"] as? String,
            let roundTitle = payload["roundTitle"] as? String,
            let actionTitle = payload["actionTitle"] as? String,
            let actionHint = payload["actionHint"] as? String,
            let stitchProgress = payload["stitchProgress"] as? Int,
            let rawExecutionState = payload["executionState"] as? String,
            let executionState = SnapshotExecutionState(rawValue: rawExecutionState),
            let canAdvance = payload["canAdvance"] as? Bool,
            let isComplete = payload["isComplete"] as? Bool,
            let updatedAtSeconds = payload["updatedAt"] as? Double
        else {
            return nil
        }

        let targetValue = payload["targetStitches"] as? Int ?? -1
        return ProjectSnapshot(
            projectID: projectID,
            title: title,
            partName: partName,
            roundTitle: roundTitle,
            actionTitle: actionTitle,
            actionHint: actionHint,
            actionNote: (payload["actionNote"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            nextActionTitle: (payload["nextActionTitle"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            stitchProgress: stitchProgress,
            targetStitches: targetValue >= 0 ? targetValue : nil,
            executionState: executionState,
            statusMessage: (payload["statusMessage"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            canAdvance: canAdvance,
            isComplete: isComplete,
            updatedAt: Date(timeIntervalSince1970: updatedAtSeconds)
        )
    }

    private func sendMessage(_ payload: [String: Any]) async throws {
        try await withCheckedThrowingContinuation { continuation in
            WCSession.default.sendMessage(payload) { _ in
                continuation.resume(returning: ())
            } errorHandler: { error in
                continuation.resume(throwing: error)
            }
        }
    }
}

extension WatchSyncCoordinator: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {}

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String : Any]) {
        Task { @MainActor in
            if let snapshot = makeSnapshot(from: applicationContext) {
                currentSnapshot = snapshot
                try? storage.save(snapshot, to: filename)
            }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String : Any]) {
        Task { @MainActor in
            let type = message["type"] as? String
            switch type {
            case "snapshot":
                if let snapshot = makeSnapshot(from: message) {
                    currentSnapshot = snapshot
                    try? storage.save(snapshot, to: filename)
                }
            case "command":
                guard
                    let projectIDString = message["projectID"] as? String,
                    let projectID = UUID(uuidString: projectIDString),
                    let rawCommand = message["command"] as? String,
                    let command = ExecutionCommand(rawValue: rawCommand)
                else {
                    return
                }
                let source = (message["source"] as? String).flatMap(ExecutionCommandSource.init(rawValue:)) ?? .sync
                onCommandReceived?(projectID, command, source)
            case "snapshot_request":
                if let snapshot = await requestSnapshotProvider?() {
                    await push(snapshot: snapshot)
                }
            default:
                break
            }
        }
    }
}

#if os(iOS)
extension WatchSyncCoordinator {
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) {}
}
#endif

#else
@MainActor
final class WatchSyncCoordinator: ObservableObject {
    @Published private(set) var currentSnapshot: ProjectSnapshot?
    var onCommandReceived: ((UUID, ExecutionCommand, ExecutionCommandSource) -> Void)?
    var requestSnapshotProvider: (() async -> ProjectSnapshot?)?

    func activate() {}
    func send(command: ExecutionCommand, projectID: UUID, source: ExecutionCommandSource) async {}
    func push(snapshot: ProjectSnapshot) async { currentSnapshot = snapshot }
    func requestSnapshot() async {}
}
#endif
