import Testing
@testable import LyricCore

struct AutomaticActivityFeedbackPolicyTests {
    @Test
    func foregroundPlaybackDetectionQueuesOneConfirmation() {
        #expect(AutomaticActivityFeedbackPolicy.shouldQueue(
            previousState: nil,
            currentState: .playing,
            isArmed: true,
            automaticLyricsEnabled: true,
            appIsActive: true
        ))
        #expect(!AutomaticActivityFeedbackPolicy.shouldQueue(
            previousState: .paused,
            currentState: .playing,
            isArmed: false,
            automaticLyricsEnabled: true,
            appIsActive: true
        ))
    }

    @Test
    func backgroundOrDisabledDetectionDoesNotQueueAHaptic() {
        #expect(!AutomaticActivityFeedbackPolicy.shouldQueue(
            previousState: .stopped,
            currentState: .playing,
            isArmed: true,
            automaticLyricsEnabled: true,
            appIsActive: false
        ))
        #expect(!AutomaticActivityFeedbackPolicy.shouldQueue(
            previousState: .stopped,
            currentState: .playing,
            isArmed: true,
            automaticLyricsEnabled: false,
            appIsActive: true
        ))
    }

    @Test
    func confirmedStopRearmsTheNextPlaybackSession() {
        #expect(AutomaticActivityFeedbackPolicy.shouldRearm(currentState: .stopped))
        #expect(!AutomaticActivityFeedbackPolicy.shouldRearm(currentState: .paused))
    }

    @Test
    func confirmationWaitsUntilTheActivityExists() {
        #expect(!AutomaticActivityFeedbackPolicy.shouldDeliver(
            isPending: true,
            activityIsRunning: false,
            appIsActive: true
        ))
        #expect(AutomaticActivityFeedbackPolicy.shouldDeliver(
            isPending: true,
            activityIsRunning: true,
            appIsActive: true
        ))
    }
}
