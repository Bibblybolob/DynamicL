import Testing
@testable import LyricCore

struct SyncOwnershipPolicyTests {
    @Test
    func foregroundPhoneOwnsAfterFreshPoll() {
        #expect(SyncOwnershipPolicy.phoneLeaseIsHealthy(
            isForeground: true,
            loopIsAlive: true,
            lastSuccessfulPollAge: 3,
            isWarmingUp: false
        ))
    }

    @Test
    func backgroundPhoneYieldsToServer() {
        #expect(!SyncOwnershipPolicy.phoneLeaseIsHealthy(
            isForeground: false,
            loopIsAlive: true,
            lastSuccessfulPollAge: 1,
            isWarmingUp: false
        ))
    }

    @Test
    func staleOrMissingPollYieldsToServer() {
        #expect(!SyncOwnershipPolicy.phoneLeaseIsHealthy(
            isForeground: true,
            loopIsAlive: true,
            lastSuccessfulPollAge: 9,
            isWarmingUp: false
        ))
        #expect(!SyncOwnershipPolicy.phoneLeaseIsHealthy(
            isForeground: true,
            loopIsAlive: true,
            lastSuccessfulPollAge: nil,
            isWarmingUp: false
        ))
    }

    @Test
    func foregroundWarmupOwnsBeforeFirstPoll() {
        #expect(SyncOwnershipPolicy.phoneLeaseIsHealthy(
            isForeground: true,
            loopIsAlive: false,
            lastSuccessfulPollAge: nil,
            isWarmingUp: true
        ))
    }
}
