#if DEBUG
    import Foundation
    import LocalAssistCore

    /// Durable envelope for cold-launch measurement campaigns.
    ///
    /// A campaign pins the conditions its samples were taken under —
    /// device, OS, build configuration, commit SHA, expected generation
    /// source — so twenty launches collected on Tuesday's debug build never
    /// silently average with five from last week's release build. Records
    /// carry their campaign ID; readers filter by it, and folding records
    /// from different campaigns into one report is structurally impossible
    /// through this API.
    ///
    /// Lifecycle is explicit: `begin` (fails if one is active), `reset`
    /// (discard campaign + records), `finalize` (return everything and
    /// close). Appends are throwing and fsync before returning — a caller
    /// that reports success has a durable record.
    public enum ColdLaunchCampaignStore {
        public struct Campaign: Codable, Equatable, Sendable {
            public var id: String
            public var startedAt: Date
            /// Device model, OS, build configuration, commit SHA, thermal
            /// and power state at campaign start.
            public var environment: RunEnvironment
            /// What the campaign intends to measure. A sample from any
            /// other source is classified `unexpectedSource`.
            public var expectedSource: GenerationSource

            /// Provenance is necessary but not sufficient for a claim. The
            /// summary also checks count, source, failures, power, thermal
            /// state, and environment consistency across every record.
            public var hasTraceableProvenance: Bool {
                MeasurementClaimPolicy.hasTraceableCommit(environment)
            }
        }

        public enum Classification: String, Codable, Sendable {
            /// A successful sample from the expected source.
            case sample
            /// Succeeded, but from the wrong source — e.g. a deterministic
            /// fallback answered in a Foundation Models campaign.
            case unexpectedSource
            /// The launch's generation failed; the typed category is kept.
            case failure
        }

        public struct Record: Codable, Equatable, Sendable {
            public var campaignID: String
            public var recordedAt: Date
            public var environment: RunEnvironment
            public var expectedSource: GenerationSource
            public var classification: Classification
            public var sample: DeviceMeasurementHarness.Sample?
            public var failure: DeviceMeasurementHarness.FailedSample?
        }

        /// Everything a report needs about the active campaign, already
        /// partitioned by classification.
        public struct Summary: Codable, Equatable, Sendable {
            public var campaign: Campaign
            public var samples: [DeviceMeasurementHarness.Sample]
            public var unexpectedSourceSamples: [DeviceMeasurementHarness.Sample]
            public var failures: [DeviceMeasurementHarness.FailedSample]
            /// True only when every requirement for an aggregate p95 claim
            /// is satisfied. Operational test success alone is not enough.
            public var claimReady: Bool
            public var claimBlockingReasons: [String]
        }

        public enum CampaignError: Error, Equatable {
            case activeCampaignExists
            case noActiveCampaign
            case recordBelongsToDifferentCampaign
        }

        // MARK: - Files

        static var directoryURL: URL {
            let documents = FileManager.default.urls(
                for: .documentDirectory,
                in: .userDomainMask
            ).first ?? FileManager.default.temporaryDirectory
            return documents.appendingPathComponent("localassist-measurements", isDirectory: true)
        }

        static var campaignURL: URL {
            directoryURL.appendingPathComponent("cold-campaign.json")
        }

        static var recordsURL: URL {
            directoryURL.appendingPathComponent("cold-records.jsonl")
        }

        // MARK: - Lifecycle

        /// Starts a campaign. Throws when one is already active — reset or
        /// finalize first; a campaign's conditions never mutate mid-flight.
        @discardableResult
        public static func begin(
            expectedSource: GenerationSource,
            environment: RunEnvironment = .current(coldStart: true)
        ) throws -> Campaign {
            guard active() == nil else {
                throw CampaignError.activeCampaignExists
            }
            let campaign = Campaign(
                id: UUID().uuidString,
                startedAt: Date(),
                environment: environment,
                expectedSource: expectedSource
            )
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(campaign).write(to: campaignURL, options: [.atomic])
            return campaign
        }

        public static func active() -> Campaign? {
            guard let data = try? Data(contentsOf: campaignURL) else {
                return nil
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try? decoder.decode(Campaign.self, from: data)
        }

        /// Discards the active campaign and every record.
        public static func reset() throws {
            for url in [campaignURL, recordsURL] where FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }

        /// Returns the campaign with all its records and closes it.
        public static func finalize() throws -> (campaign: Campaign, records: [Record]) {
            guard let campaign = active() else {
                throw CampaignError.noActiveCampaign
            }
            let campaignRecords = records(for: campaign)
            try reset()
            return (campaign, campaignRecords)
        }

        // MARK: - Records

        /// Appends one record durably: encode, write, fsync. Throws on any
        /// step — the caller must not report success (or show a completion
        /// marker) unless this returned.
        public static func append(_ record: Record) throws {
            guard let campaign = active() else {
                throw CampaignError.noActiveCampaign
            }
            guard record.campaignID == campaign.id else {
                throw CampaignError.recordBelongsToDifferentCampaign
            }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            var data = try encoder.encode(record)
            data.append(Data("\n".utf8))

            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: recordsURL.path) {
                try Data().write(to: recordsURL, options: [.atomic])
            }
            let handle = try FileHandle(forWritingTo: recordsURL)
            defer {
                try? handle.close()
            }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            // Durability is the contract: the completion marker and the
            // "collected" return value key off this call returning.
            try handle.synchronize()
        }

        /// Records belonging to this campaign, in append order. Lines from
        /// any other campaign (stale files, older runs) are excluded — the
        /// filter is the never-fold guarantee.
        public static func records(for campaign: Campaign) -> [Record] {
            guard let data = try? Data(contentsOf: recordsURL) else {
                return []
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return data
                .split(separator: UInt8(ascii: "\n"))
                .compactMap { try? decoder.decode(Record.self, from: $0) }
                .filter { $0.campaignID == campaign.id }
        }

        /// Partitioned view of the active campaign for report embedding;
        /// nil when no campaign is active.
        public static func summaryOfActiveCampaign() -> Summary? {
            guard let campaign = active() else {
                return nil
            }
            let all = records(for: campaign)
            let samples = all.filter { $0.classification == .sample }.compactMap(\.sample)
            let unexpectedSourceSamples = all.filter { $0.classification == .unexpectedSource }
                .compactMap(\.sample)
            let failures = all.filter { $0.classification == .failure }.compactMap(\.failure)
            let blockers = claimBlockers(ClaimEvidence(
                campaign: campaign,
                records: all,
                samples: samples,
                unexpectedSourceSamples: unexpectedSourceSamples,
                failures: failures
            ))
            return Summary(
                campaign: campaign,
                samples: samples,
                unexpectedSourceSamples: unexpectedSourceSamples,
                failures: failures,
                claimReady: blockers.isEmpty,
                claimBlockingReasons: blockers
            )
        }

        private struct ClaimEvidence {
            var campaign: Campaign
            var records: [Record]
            var samples: [DeviceMeasurementHarness.Sample]
            var unexpectedSourceSamples: [DeviceMeasurementHarness.Sample]
            var failures: [DeviceMeasurementHarness.FailedSample]
        }

        private static func claimBlockers(_ evidence: ClaimEvidence) -> [String] {
            provenanceBlockers(evidence)
                + recordIntegrityBlockers(evidence)
                + environmentBlockers(evidence)
        }

        private static func provenanceBlockers(_ evidence: ClaimEvidence) -> [String] {
            var blockers: [String] = []
            if !evidence.campaign.hasTraceableProvenance {
                blockers.append("missing or dirty commit SHA")
            }
            if !MeasurementClaimPolicy.hasStablePower(evidence.campaign.environment) {
                blockers.append("Low Power Mode was enabled")
            }
            if evidence.samples.count < MeasurementClaimPolicy.minimumP95SampleCount {
                blockers.append(
                    "expected at least \(MeasurementClaimPolicy.minimumP95SampleCount) "
                        + "expected-source process-cold samples, recorded \(evidence.samples.count)"
                )
            }
            if !evidence.unexpectedSourceSamples.isEmpty {
                blockers.append(
                    "\(evidence.unexpectedSourceSamples.count) cold samples used an unexpected source"
                )
            }
            if !evidence.failures.isEmpty {
                blockers.append("\(evidence.failures.count) cold launches failed")
            }
            return blockers
        }

        private static func recordIntegrityBlockers(_ evidence: ClaimEvidence) -> [String] {
            var blockers: [String] = []
            let malformedRecordCount = evidence.records.filter { record in
                switch record.classification {
                case .sample, .unexpectedSource:
                    record.sample == nil || record.failure != nil
                case .failure:
                    record.sample != nil || record.failure == nil
                }
            }.count
            if malformedRecordCount > 0 {
                blockers.append("\(malformedRecordCount) cold records were malformed")
            }
            let mislabeledSourceCount = evidence.samples.filter {
                $0.source != evidence.campaign.expectedSource
            }.count
            if mislabeledSourceCount > 0 {
                blockers.append("\(mislabeledSourceCount) expected-source samples were mislabeled")
            }
            let wrongCohortCount = evidence.records.compactMap(\.sample)
                .filter { $0.cohort != .processCold }.count
            if wrongCohortCount > 0 {
                blockers.append("\(wrongCohortCount) cold samples were not process-cold")
            }
            let wrongExpectedSourceCount = evidence.records.filter {
                $0.expectedSource != evidence.campaign.expectedSource
            }.count
            if wrongExpectedSourceCount > 0 {
                blockers.append("\(wrongExpectedSourceCount) records changed expected source")
            }
            return blockers
        }

        private static func environmentBlockers(_ evidence: ClaimEvidence) -> [String] {
            var blockers: [String] = []
            let inconsistentEnvironmentCount = evidence.records.filter {
                !MeasurementClaimPolicy.matchesPinnedEnvironment(
                    $0.environment,
                    campaign: evidence.campaign.environment
                )
            }.count
            if inconsistentEnvironmentCount > 0 {
                blockers.append("\(inconsistentEnvironmentCount) records changed pinned environment")
            }
            let thermallyInvalidCount = evidence.records.filter {
                !MeasurementClaimPolicy.isThermallyEligible($0.environment)
            }.count
            if thermallyInvalidCount > 0 {
                blockers.append("\(thermallyInvalidCount) cold samples exceeded the thermal budget")
            }
            return blockers
        }
    }
#endif
