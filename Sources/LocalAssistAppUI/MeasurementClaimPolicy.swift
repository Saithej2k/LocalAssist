#if DEBUG
    import Foundation
    import LocalAssistCore

    /// One conservative definition of when device measurements are safe to
    /// quote. Reports keep every rejected attempt, but a headline number is
    /// blocked unless provenance, sample count, source, power, and thermal
    /// conditions all agree.
    enum MeasurementClaimPolicy {
        static let minimumP95SampleCount = 20

        static func hasTraceableCommit(_ environment: RunEnvironment) -> Bool {
            guard let commit = environment.commitSHA?.trimmingCharacters(in: .whitespacesAndNewlines),
                  (7 ... 40).contains(commit.count),
                  commit.unicodeScalars.allSatisfy({ scalar in
                      switch scalar.value {
                      case 48 ... 57, 65 ... 70, 97 ... 102:
                          true
                      default:
                          false
                      }
                  })
            else {
                return false
            }
            return true
        }

        static func isThermallyEligible(_ environment: RunEnvironment) -> Bool {
            environment.thermalState == "nominal" || environment.thermalState == "fair"
        }

        static func hasStablePower(_ environment: RunEnvironment) -> Bool {
            !environment.lowPowerMode
        }

        /// Thermal state and cold/warm classification legitimately vary per
        /// sample. Everything else must stay pinned to the campaign build.
        static func matchesPinnedEnvironment(
            _ environment: RunEnvironment,
            campaign: RunEnvironment
        ) -> Bool {
            environment.deviceModel == campaign.deviceModel
                && environment.osVersion == campaign.osVersion
                && environment.buildMode == campaign.buildMode
                && environment.commitSHA == campaign.commitSHA
                && environment.lowPowerMode == campaign.lowPowerMode
        }

        static func currentThermalStateIsEligible() -> Bool {
            isThermallyEligible(.current(coldStart: false))
        }

        /// Waits without doing model work so a measurement never knowingly
        /// starts under serious/critical thermal pressure.
        static func waitForThermalEligibility(
            timeout: Duration,
            pollInterval: Duration
        ) async -> Bool {
            guard !Task.isCancelled else {
                return false
            }
            if currentThermalStateIsEligible() {
                return true
            }

            let clock = ContinuousClock()
            let startedAt = clock.now
            while startedAt.duration(to: clock.now) < timeout {
                do {
                    try await Task.sleep(for: pollInterval)
                } catch {
                    return false
                }
                if currentThermalStateIsEligible() {
                    return true
                }
            }
            return false
        }
    }
#endif
