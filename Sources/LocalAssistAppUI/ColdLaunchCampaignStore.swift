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

            /// A campaign without a commit SHA cannot say which code it
            /// measured — its numbers stay unclaimed. The app stamps
            /// `LocalAssistCommitSHA` into device builds; XCUITest launches
            /// forward `LOCALASSIST_COMMIT_SHA` per the documented command.
            public var isClaimReady: Bool {
                environment.commitSHA?.isEmpty == false
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
            /// False when the campaign lacks a commit SHA — the samples
            /// are preserved but must not be quoted as measurements of any
            /// particular build.
            public var claimReady: Bool
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
            return Summary(
                campaign: campaign,
                samples: all.filter { $0.classification == .sample }.compactMap(\.sample),
                unexpectedSourceSamples: all.filter { $0.classification == .unexpectedSource }
                    .compactMap(\.sample),
                failures: all.filter { $0.classification == .failure }.compactMap(\.failure),
                claimReady: campaign.isClaimReady
            )
        }
    }
#endif
