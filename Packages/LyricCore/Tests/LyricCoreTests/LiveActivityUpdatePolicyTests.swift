import Testing
@testable import LyricCore

struct LiveActivityUpdatePolicyTests {
    @Test
    func changedLineSendsWhileBelowTheRateLimit() {
        #expect(LiveActivityUpdatePolicy.shouldSendLineChange(
            lineChanged: true,
            hasUsableSchedule: false,
            timeSinceLastSend: 2,
            sendsInLastMinute: 8
        ))
    }

    @Test
    func scheduledLineDoesNotUseAnotherActivityUpdate() {
        #expect(!LiveActivityUpdatePolicy.shouldSendLineChange(
            lineChanged: true,
            hasUsableSchedule: true,
            timeSinceLastSend: 30,
            sendsInLastMinute: 0
        ))
    }

    @Test
    func unchangedOrRapidLineDoesNotSend() {
        #expect(!LiveActivityUpdatePolicy.shouldSendLineChange(
            lineChanged: false,
            hasUsableSchedule: false,
            timeSinceLastSend: 2,
            sendsInLastMinute: 8
        ))
        #expect(!LiveActivityUpdatePolicy.shouldSendLineChange(
            lineChanged: true,
            hasUsableSchedule: false,
            timeSinceLastSend: 0.2,
            sendsInLastMinute: 8
        ))
    }

    @Test
    func lineUpdatesSlowAtTheMinuteLimit() {
        #expect(!LiveActivityUpdatePolicy.shouldSendLineChange(
            lineChanged: true,
            hasUsableSchedule: false,
            timeSinceLastSend: 1,
            sendsInLastMinute: 12
        ))
        #expect(LiveActivityUpdatePolicy.shouldSendLineChange(
            lineChanged: true,
            hasUsableSchedule: false,
            timeSinceLastSend: 5,
            sendsInLastMinute: 12
        ))
    }
}
