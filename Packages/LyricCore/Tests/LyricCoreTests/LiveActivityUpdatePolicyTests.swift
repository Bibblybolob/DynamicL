import Testing
@testable import LyricCore

struct LiveActivityUpdatePolicyTests {
    @Test
    func changedLineSendsWhileBelowTheRateLimit() {
        #expect(LiveActivityUpdatePolicy.shouldSendLineChange(
            lineChanged: true,
            timeSinceLastSend: 2,
            sendsInLastMinute: 8
        ))
    }

    @Test
    func unchangedOrRapidLineDoesNotSend() {
        #expect(!LiveActivityUpdatePolicy.shouldSendLineChange(
            lineChanged: false,
            timeSinceLastSend: 2,
            sendsInLastMinute: 8
        ))
        #expect(!LiveActivityUpdatePolicy.shouldSendLineChange(
            lineChanged: true,
            timeSinceLastSend: 0.2,
            sendsInLastMinute: 8
        ))
    }

    @Test
    func lineUpdatesStopAtTheMinuteLimit() {
        #expect(!LiveActivityUpdatePolicy.shouldSendLineChange(
            lineChanged: true,
            timeSinceLastSend: 2,
            sendsInLastMinute: 20
        ))
    }
}
