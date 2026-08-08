import Foundation

final class HydrationTracker {
    enum Event: Equatable {
        case reminder
    }

    var reminderInterval: TimeInterval {
        didSet {
            guard isEnabled, !isAwaitingDrink else { return }
            nextReminderAt = Date().addingTimeInterval(reminderInterval)
        }
    }

    var repeatInterval: TimeInterval = 2 * 60

    private(set) var isEnabled: Bool
    private(set) var isAwaitingDrink = false
    private(set) var isPresent = false
    private var nextReminderAt: Date?
    private var nextRepeatAt: Date?

    init(
        reminderInterval: TimeInterval,
        isEnabled: Bool
    ) {
        self.reminderInterval = reminderInterval
        self.isEnabled = isEnabled
    }

    func setEnabled(_ enabled: Bool, now: Date = Date()) {
        isEnabled = enabled
        if enabled {
            if nextReminderAt == nil, !isAwaitingDrink {
                nextReminderAt = now.addingTimeInterval(reminderInterval)
            }
        } else {
            isAwaitingDrink = false
            nextReminderAt = nil
            nextRepeatAt = nil
        }
    }

    func updatePresence(_ present: Bool, now: Date = Date()) {
        isPresent = present
        guard isEnabled, present else { return }
        if nextReminderAt == nil, !isAwaitingDrink {
            nextReminderAt = now.addingTimeInterval(reminderInterval)
        }
    }

    func tick(now: Date = Date()) -> Event? {
        guard isEnabled, isPresent else { return nil }

        if isAwaitingDrink {
            guard let nextRepeatAt, now >= nextRepeatAt else {
                return nil
            }
            self.nextRepeatAt = now.addingTimeInterval(repeatInterval)
            return .reminder
        }

        guard let nextReminderAt, now >= nextReminderAt else {
            return nil
        }
        isAwaitingDrink = true
        self.nextReminderAt = nil
        nextRepeatAt = now.addingTimeInterval(repeatInterval)
        return .reminder
    }

    func requestDrinkNow(now: Date = Date()) {
        guard isEnabled else { return }
        isAwaitingDrink = true
        nextReminderAt = nil
        nextRepeatAt = now.addingTimeInterval(repeatInterval)
    }

    @discardableResult
    func confirmDrink(now: Date = Date()) -> Bool {
        guard isEnabled, isAwaitingDrink else { return false }
        isAwaitingDrink = false
        nextRepeatAt = nil
        nextReminderAt = now.addingTimeInterval(reminderInterval)
        return true
    }

    func timeUntilNextAction(now: Date = Date()) -> TimeInterval? {
        let target = isAwaitingDrink ? nextRepeatAt : nextReminderAt
        guard let target else { return nil }
        return max(0, target.timeIntervalSince(now))
    }
}

enum DrinkingGestureObservation {
    case unavailable
    case noHand
    case away
    case nearMouth
}

struct DrinkingGestureDetector {
    var requiredReadyFrames = 2
    var requiredNearFrames = 3
    var minimumHoldDuration: TimeInterval = 1
    var requiredReleaseFrames = 2
    var toleratedMissingFramesDuringHold = 2
    var toleratedUnavailableFramesAfterHold = 3
    var maximumObservationGap: TimeInterval = 1.25
    var cooldown: TimeInterval = 20

    private var readyFrames = 0
    private var isArmed = false
    private var nearFrames = 0
    private var missingFramesDuringHold = 0
    private var holdStartedAt: TimeInterval?
    private var holdSatisfied = false
    private var releaseFrames = 0
    private var unavailableFramesAfterHold = 0
    private var lastObservationAt: TimeInterval?
    private var nextAllowedDetectionAt: TimeInterval = 0

    mutating func ingest(
        _ observation: DrinkingGestureObservation,
        at time: TimeInterval
    ) -> Bool {
        guard time >= nextAllowedDetectionAt else {
            resetProgress()
            return false
        }
        if let lastObservationAt,
           time - lastObservationAt > maximumObservationGap {
            resetProgress()
        }
        lastObservationAt = time

        switch observation {
        case .unavailable:
            return ingestUnavailable(at: time)
        case .noHand:
            return ingestNoHand(at: time)
        case .away:
            return ingestAway(at: time)
        case .nearMouth:
            return ingestNearMouth(at: time)
        }
    }

    private mutating func ingestNearMouth(at time: TimeInterval) -> Bool {
        guard isArmed else {
            readyFrames = 0
            return false
        }

        if nearFrames == 0 {
            holdStartedAt = time
        }
        nearFrames += 1
        missingFramesDuringHold = 0
        releaseFrames = 0
        unavailableFramesAfterHold = 0

        if nearFrames >= requiredNearFrames,
           let holdStartedAt,
           time - holdStartedAt >= minimumHoldDuration {
            holdSatisfied = true
        }
        return false
    }

    private mutating func ingestAway(at time: TimeInterval) -> Bool {
        guard nearFrames > 0 else {
            readyFrames = min(requiredReadyFrames, readyFrames + 1)
            isArmed = readyFrames >= requiredReadyFrames
            return false
        }

        guard holdSatisfied else {
            resetProgress()
            readyFrames = 1
            isArmed = requiredReadyFrames <= 1
            return false
        }

        releaseFrames += 1
        unavailableFramesAfterHold = 0
        guard releaseFrames >= requiredReleaseFrames else {
            return false
        }
        return completeDetection(at: time)
    }

    private mutating func ingestNoHand(at time: TimeInterval) -> Bool {
        guard nearFrames > 0 else {
            readyFrames = min(requiredReadyFrames, readyFrames + 1)
            isArmed = readyFrames >= requiredReadyFrames
            return false
        }

        guard holdSatisfied else {
            missingFramesDuringHold += 1
            if missingFramesDuringHold > toleratedMissingFramesDuringHold {
                resetProgress()
            }
            return false
        }

        releaseFrames += 1
        unavailableFramesAfterHold = 0
        guard releaseFrames >= requiredReleaseFrames else {
            return false
        }
        return completeDetection(at: time)
    }

    private mutating func ingestUnavailable(at time: TimeInterval) -> Bool {
        guard nearFrames > 0 else {
            resetProgress()
            return false
        }

        if holdSatisfied {
            unavailableFramesAfterHold += 1
            releaseFrames = 0
            if unavailableFramesAfterHold
                > toleratedUnavailableFramesAfterHold {
                resetProgress()
            }
            return false
        }

        missingFramesDuringHold += 1
        if missingFramesDuringHold > toleratedMissingFramesDuringHold {
            resetProgress()
        }
        return false
    }

    private mutating func completeDetection(at time: TimeInterval) -> Bool {
        resetProgress()
        nextAllowedDetectionAt = time + cooldown
        return true
    }

    private mutating func resetProgress() {
        readyFrames = 0
        isArmed = false
        nearFrames = 0
        missingFramesDuringHold = 0
        holdStartedAt = nil
        holdSatisfied = false
        releaseFrames = 0
        unavailableFramesAfterHold = 0
    }

    mutating func reset() {
        resetProgress()
        lastObservationAt = nil
        nextAllowedDetectionAt = 0
    }
}
