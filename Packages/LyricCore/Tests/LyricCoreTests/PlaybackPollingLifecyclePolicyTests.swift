import Testing
@testable import LyricCore

struct PlaybackPollingLifecyclePolicyTests {
    @Test
    func newOrFreshLoopIsReused() {
        #expect(PlaybackPollingLifecyclePolicy.shouldReuseLoop(
            isPolling: true,
            lastLoopActivityAge: nil,
            staleAfter: 20
        ))
        #expect(PlaybackPollingLifecyclePolicy.shouldReuseLoop(
            isPolling: true,
            lastLoopActivityAge: 2,
            staleAfter: 20
        ))
    }

    @Test
    func stoppedOrStaleLoopIsRebuilt() {
        #expect(!PlaybackPollingLifecyclePolicy.shouldReuseLoop(
            isPolling: false,
            lastLoopActivityAge: 1,
            staleAfter: 20
        ))
        #expect(!PlaybackPollingLifecyclePolicy.shouldReuseLoop(
            isPolling: true,
            lastLoopActivityAge: 20,
            staleAfter: 20
        ))
    }

    @Test
    func watchdogRunsForForegroundOrActiveLocalSession() {
        #expect(PlaybackPollingLifecyclePolicy.shouldRunWatchdog(
            isConnected: true,
            isForeground: true,
            localSessionActive: false
        ))
        #expect(PlaybackPollingLifecyclePolicy.shouldRunWatchdog(
            isConnected: true,
            isForeground: false,
            localSessionActive: true
        ))
        #expect(!PlaybackPollingLifecyclePolicy.shouldRunWatchdog(
            isConnected: false,
            isForeground: true,
            localSessionActive: true
        ))
    }
}
