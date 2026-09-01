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
        if isForeground && isWarmingUp { return true }
        guard loopIsAlive,
              let lastSuccessfulPollAge,
              lastSuccessfulPollAge.isFinite,
              lastSuccessfulPollAge >= 0,
              lastSuccessfulPollAge <= maximumPollAge else {
            return false
        }
        // The phone remains the preferred writer while iOS still lets its
        // poller obtain current Spotify data. When iOS suspends the process,
        // heartbeats stop and the existing lease expires naturally. This
        // avoids an immediate background handoff to a server that may not yet
        // have a usable Spotify registration.
        return true
    }
}
