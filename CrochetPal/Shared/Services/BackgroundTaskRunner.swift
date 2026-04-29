import Foundation

#if os(iOS)
import UIKit
#endif

protocol BackgroundTaskRunning {
    func run(named name: String, operation: @escaping () async -> Void) async
}

struct NoopBackgroundTaskRunner: BackgroundTaskRunning {
    func run(named name: String, operation: @escaping () async -> Void) async {
        await operation()
    }
}

#if os(iOS)
@MainActor
private final class BackgroundTaskAssertion {
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    init(name: String) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            Task { @MainActor in
                self?.end()
            }
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}

struct ApplicationBackgroundTaskRunner: BackgroundTaskRunning {
    func run(named name: String, operation: @escaping () async -> Void) async {
        let assertion = await MainActor.run {
            BackgroundTaskAssertion(name: name)
        }
        await operation()
        await MainActor.run {
            assertion.end()
        }
    }
}
#else
typealias ApplicationBackgroundTaskRunner = NoopBackgroundTaskRunner
#endif
