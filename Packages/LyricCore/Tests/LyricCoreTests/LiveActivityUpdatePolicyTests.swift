import Testing
@testable import LyricCore

struct LiveActivityUpdatePolicyTests {
    @Test func loadingPlaceholderRecognitionCoversServerAndPhonePunctuation() {
        #expect(LiveActivityUpdatePolicy.isLoadingPlaceholder("Finding lyrics…"))
        #expect(LiveActivityUpdatePolicy.isLoadingPlaceholder(" Finding lyrics... "))
        #expect(LiveActivityUpdatePolicy.isLoadingPlaceholder("Waiting for Spotify playback…"))
        #expect(!LiveActivityUpdatePolicy.isLoadingPlaceholder("And it goes around like this"))
    }

    @Test func loadingPlaceholderRecoveryUsesBoundedBackoff() {
        #expect(LiveActivityUpdatePolicy.shouldRetryLoadingPlaceholder(
            isPlaceholderApplied: true,
            attempts: 0,
            timeSinceLastAttempt: 0
        ))
        #expect(!LiveActivityUpdatePolicy.shouldRetryLoadingPlaceholder(
            isPlaceholderApplied: true,
            attempts: 1,
            timeSinceLastAttempt: 1.9
        ))
        #expect(LiveActivityUpdatePolicy.shouldRetryLoadingPlaceholder(
            isPlaceholderApplied: true,
            attempts: 1,
            timeSinceLastAttempt: 2
        ))
        #expect(LiveActivityUpdatePolicy.shouldRetryLoadingPlaceholder(
            isPlaceholderApplied: true,
            attempts: 3,
            timeSinceLastAttempt: 8
        ))
        #expect(!LiveActivityUpdatePolicy.shouldRetryLoadingPlaceholder(
            isPlaceholderApplied: true,
            attempts: 4,
            timeSinceLastAttempt: 60
        ))
        #expect(!LiveActivityUpdatePolicy.shouldRetryLoadingPlaceholder(
            isPlaceholderApplied: false,
            attempts: 0,
            timeSinceLastAttempt: 60
        ))
    }

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
