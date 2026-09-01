import Foundation

/// Decides when the phone can suppress the background APNs writer.
public enum SyncOwnershipPolicy {
    public static func phoneLeaseIsHealthy(
        isForeground: Bool,
        loopIsAlive: Bool,
        lastSuccessfulPollAge: TimeInterval?,
        isWarmingUp: Bool,
        maximumPollAge: TimeInterval = 8
    ) -> Bool {
        guard isForeground else { return false }
        if isWarmingUp { return true }
        guard loopIsAlive,
              let lastSuccessfulPollAge,
              lastSuccessfulPollAge.isFinite,
              lastSuccessfulPollAge >= 0,
              lastSuccessfulPollAge <= maximumPollAge else {
            return false
        }
        return true
    }
}
