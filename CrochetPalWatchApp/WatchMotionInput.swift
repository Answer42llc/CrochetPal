import CoreMotion
import Foundation

final class WatchMotionInput {
    var onCommand: ((ExecutionCommand) -> Void)?

    private let motionManager = CMMotionManager()
    private let queue = OperationQueue()
    private let threshold: Double
    private let cooldown: TimeInterval
    private var lastTriggerAt: Date = .distantPast
    private var baselineRoll: Double?

    init(threshold: Double = 0.9, cooldown: TimeInterval = 1.2) {
        self.threshold = threshold
        self.cooldown = cooldown
        self.queue.qualityOfService = .userInitiated
    }

    func start() {
        guard motionManager.isDeviceMotionAvailable else { return }
        motionManager.deviceMotionUpdateInterval = 0.2
        motionManager.startDeviceMotionUpdates(to: queue) { [weak self] motion, _ in
            guard let self, let motion else { return }
            let roll = motion.attitude.roll
            if self.baselineRoll == nil {
                self.baselineRoll = roll
                return
            }

            guard Date().timeIntervalSince(self.lastTriggerAt) > self.cooldown else { return }
            let delta = roll - (self.baselineRoll ?? roll)
            if delta >= self.threshold {
                self.lastTriggerAt = .now
                DispatchQueue.main.async {
                    self.onCommand?(.forward)
                }
            } else if delta <= -self.threshold {
                self.lastTriggerAt = .now
                DispatchQueue.main.async {
                    self.onCommand?(.undo)
                }
            }
        }
    }
}
