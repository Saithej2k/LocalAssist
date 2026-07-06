import Foundation
import XCTest
import LocalAssistAppUI
@testable import LocalAssistCore
import LocalAssistEvalKit
import LocalAssistSystemTools

final class LocalAssistCoreTests: XCTestCase {
    // MARK: - Validation

    func testMalformedInputsThrow() throws {
        let validator = RequestValidator(maxCharacters: 20)

        XCTAssertThrowsError(try validator.validate(AssistantRequest(sourceText: "   "))) { error in
            XCTAssertEqual(error as? LocalAssistError, .emptyInput)
        }
        XCTAssertThrowsError(
            try validator.validate(AssistantRequest(sourceText: String(repeating: "a", count: 21)))
        ) { error in
            XCTAssertEqual(error as? LocalAssistError, .inputTooLong(actual: 21, maximum: 20))
        }
        XCTAssertThrowsError(
            try validator.validate(AssistantRequest(sourceText: "Review notes", maxSuggestions: 0))
        ) { error in
            XCTAssertEqual(error as? LocalAssistError, .invalidSuggestionLimit(0))
        }
    }

    func testRequestValidationPreservesInputKind() throws {
        let validator = RequestValidator()
        let request = AssistantRequest(
            sourceText: "  ask Priya for meeting notes tomorrow  ",
            maxSuggestions: 3,
            inputKind: .meeting
        )

        let validated = try validator.validate(request)

        XCTAssertEqual(validated.sourceText, "ask Priya for meeting notes tomorrow")
        XCTAssertEqual(validated.inputKind, .meeting)
    }

    func testLegacyRequestPayloadDefaultsToNoteInputKind() throws {
        let legacyJSON = """
        {"sourceText":"Review launch notes","localeIdentifier":"en_US","maxSuggestions":5,"isRefinement":false}
        """

        let decoded = try JSONDecoder().decode(AssistantRequest.self, from: Data(legacyJSON.utf8))

        XCTAssertEqual(decoded.inputKind, .note)
    }

    // MARK: - Availability & fallback policy

    func testUnavailableModelFallsBackWithTypedReason() async throws {
        let model = StaticStructuredModelClient(
            state: .unavailable(ModelUnavailability(reason: .deviceNotEligible))
        )
        let service = LocalAssistService(model: model)
        let summary = try await service.summarize(
            AssistantRequest(sourceText: "Review the launch checklist by Friday.")
        )

        XCTAssertEqual(summary.source, .deterministicFallback)
        XCTAssertEqual(summary.diagnostics.availability.unavailability?.reason, .deviceNotEligible)
        XCTAssertEqual(summary.suggestions.first?.action, .reminder)
    }

    func testEachUnavailabilityReasonProducesDistinctGuidance() {
        let guidance = ModelUnavailabilityReason.allCases.map {
            ModelUnavailability(reason: $0).userGuidance
        }
        XCTAssertEqual(Set(guidance).count, guidance.count)
    }

    func testGuardrailViolationFallsBackWithDiagnostics() async throws {
        let model = StaticStructuredModelClient(
            failure: .guardrailViolation(detail: "sensitive content")
        )
        let service = LocalAssistService(model: model)

        let summary = try await service.summarize(AssistantRequest(sourceText: "Review the launch checklist."))

        XCTAssertEqual(summary.source, .deterministicFallback)
        XCTAssertTrue(summary.diagnostics.fallbackReason?.contains("guardrailViolation") == true)
        XCTAssertTrue(GenerationFailure.guardrailViolation(detail: "sensitive content").allowsDeterministicFallback)
    }

    func testMidStreamUnavailabilityStillFallsBack() async throws {
        let model = StaticStructuredModelClient(
            failure: .modelUnavailable(ModelUnavailability(reason: .modelNotReady))
        )
        let service = LocalAssistService(model: model)
        let summary = try await service.summarize(
            AssistantRequest(sourceText: "Send Mira blockers by Friday.")
        )

        XCTAssertEqual(summary.source, .deterministicFallback)
        XCTAssertEqual(summary.diagnostics.availability.unavailability?.reason, .modelNotReady)
    }

    func testIncompleteStreamFallsBackWithDiagnostics() async throws {
        let model = StaticStructuredModelClient(
            script: [StructuredSummaryPartial(overview: "Partial only", isComplete: false)]
        )
        let service = LocalAssistService(model: model)

        let summary = try await service.summarize(AssistantRequest(sourceText: "Review notes tomorrow."))

        XCTAssertEqual(summary.source, .deterministicFallback)
        XCTAssertTrue(summary.diagnostics.fallbackReason?.contains("decodingFailure") == true)
    }

    func testContextWindowFailureFallsBackWithDiagnostics() async throws {
        let model = StaticStructuredModelClient(
            failure: .contextWindowExceeded(detail: "too much transcript")
        )
        let service = LocalAssistService(model: model)

        let summary = try await service.summarize(AssistantRequest(sourceText: "Summarize this and follow up tomorrow."))

        XCTAssertEqual(summary.source, .deterministicFallback)
        XCTAssertTrue(summary.diagnostics.fallbackReason?.contains("contextWindowExceeded") == true)
    }

    // MARK: - Guided generation path

    func testTypedModelOutputUsesFoundationSource() async throws {
        let service = LocalAssistService(model: StaticStructuredModelClient.completing(with: .mira))
        let summary = try await service.summarize(
            AssistantRequest(sourceText: "Send Mira blockers by Friday.")
        )

        XCTAssertEqual(summary.source, .foundationModels)
        XCTAssertEqual(summary.suggestions.first?.priority, .high)
        XCTAssertEqual(summary.actionDrafts.first?.kind, .messageDraft)
        XCTAssertEqual(summary.suggestions.first?.dueHint, "Friday")
    }

    func testNormalizerDropsPlaceholderDueHintAndDeduplicates() async throws {
        var partial = StructuredSummaryPartial.mira
        partial.suggestions[0].dueHint = "Optional natural language deadline"
        partial.keyPoints = ["Send Mira blockers", "send mira blockers", "Schedule the sync"]

        let service = LocalAssistService(model: StaticStructuredModelClient.completing(with: partial))
        let summary = try await service.summarize(
            AssistantRequest(sourceText: "Send Mira blockers.")
        )

        XCTAssertNil(summary.suggestions.first?.dueHint)
        XCTAssertEqual(summary.keyPoints, ["Send Mira blockers", "Schedule the sync"])
    }

    func testStreamingUpdatesExposeTypedPartialsBeforeFinalSummary() async throws {
        let script = [
            StructuredSummaryPartial(overview: "A launch sync needs a calendar hold."),
            StructuredSummaryPartial(
                overview: "A launch sync needs a calendar hold.",
                keyPoints: ["Schedule the launch sync"]
            ),
            StructuredSummaryPartial.launchSync,
        ]
        let model = StaticStructuredModelClient(script: script)
        let service = LocalAssistService(model: model)

        var overviewSeenWhileStreaming = false
        var sawSuggestionlessPartial = false
        var summary: StructuredSummary?

        for try await update in service.streamSummary(
            AssistantRequest(sourceText: "Schedule a launch sync next week and share the agenda.")
        ) {
            if update.phase == .streamingModel, let partial = update.partial {
                if partial.overview != nil, !partial.isComplete {
                    overviewSeenWhileStreaming = true
                }
                if partial.suggestions.isEmpty {
                    sawSuggestionlessPartial = true
                }
            }
            if let final = update.summary {
                summary = final
            }
        }

        XCTAssertTrue(overviewSeenWhileStreaming, "overview should stream before completion")
        XCTAssertTrue(sawSuggestionlessPartial, "early snapshots should predate suggestions")
        XCTAssertEqual(summary?.source, .foundationModels)
        XCTAssertEqual(summary?.suggestions.first?.action, .calendarHold)
    }

    // MARK: - Concurrency & cancellation

    func testConcurrentRequestsComplete() async throws {
        let service = LocalAssistService()

        let summaries = try await withThrowingTaskGroup(of: StructuredSummary.self) { group in
            for index in 0 ..< 20 {
                group.addTask {
                    try await service.summarize(
                        AssistantRequest(
                            sourceText: "Review item \(index) and schedule a design sync next week.",
                            maxSuggestions: 3
                        )
                    )
                }
            }

            var output: [StructuredSummary] = []
            for try await summary in group {
                output.append(summary)
            }
            return output
        }

        XCTAssertEqual(summaries.count, 20)
        XCTAssertTrue(summaries.allSatisfy { $0.source == .deterministicFallback })
        XCTAssertTrue(summaries.allSatisfy { !$0.suggestions.isEmpty })
    }

    func testCancellationPropagates() async {
        let model = StaticStructuredModelClient(
            script: [.launchSync],
            initialDelayNanoseconds: 2_000_000_000
        )
        let service = LocalAssistService(model: model)
        let task = Task {
            try await service.summarize(
                AssistantRequest(sourceText: "Review cancellation behavior tomorrow.")
            )
        }

        try? await Task.sleep(nanoseconds: 20_000_000)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("cancellation did not propagate")
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("expected CancellationError, received \(error)")
        }
    }

    func testStreamingCancellationPropagates() async {
        let model = StaticStructuredModelClient(
            script: [.launchSync],
            chunkDelayNanoseconds: 2_000_000_000
        )
        let service = LocalAssistService(model: model)
        let task = Task {
            var updateCount = 0
            for try await _ in service.streamSummary(
                AssistantRequest(sourceText: "Review streaming cancellation tomorrow.")
            ) {
                updateCount += 1
            }
            try Task.checkCancellation()
            return updateCount
        }

        try? await Task.sleep(nanoseconds: 20_000_000)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("streaming cancellation did not propagate")
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("expected streaming CancellationError, received \(error)")
        }
    }

    // MARK: - Offline fallback

    func testOfflineExecutionUsesDeterministicFallback() async throws {
        let service = LocalAssistService()
        let summary = try await service.summarize(
            AssistantRequest(
                sourceText: "Prepare release notes, update the checklist, and follow up tomorrow.",
                maxSuggestions: 4
            )
        )

        XCTAssertEqual(summary.source, .deterministicFallback)
        XCTAssertFalse(summary.diagnostics.availability.isAvailable)
        XCTAssertGreaterThanOrEqual(summary.actionDrafts.count, 2)
    }

    func testDeterministicFallbackIsStable() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let fallback = DeterministicFallbackGenerator(clock: .frozen, calendar: calendar)
        let service = LocalAssistService(fallback: fallback)
        let request = AssistantRequest(
            sourceText: "Schedule a launch sync next week and send the agenda to Mira.",
            maxSuggestions: 3
        )

        let first = try await service.summarize(request)
        let second = try await service.summarize(request)
        let firstData = try SummaryFormatter.jsonData(first, prettyPrinted: false)
        let secondData = try SummaryFormatter.jsonData(second, prettyPrinted: false)

        XCTAssertEqual(first.overview, second.overview)
        XCTAssertEqual(first.keyPoints, second.keyPoints)
        XCTAssertEqual(first.suggestions, second.suggestions)
        XCTAssertEqual(first.actionDrafts, second.actionDrafts)
        XCTAssertEqual(firstData, secondData)
        XCTAssertNotNil(first.suggestions.first(where: { $0.title.lowercased().contains("schedule") })?.dueDate)
    }

    // MARK: - Metrics & history

    func testSummarizeWithMetricsCapturesRun() async throws {
        let run = try await measuredFallbackRun()
        XCTAssertEqual(run.summary.source, .deterministicFallback)
        XCTAssertEqual(run.metrics.source, .deterministicFallback)
        XCTAssertGreaterThanOrEqual(run.metrics.durationMilliseconds, 0)
        XCTAssertEqual(run.metrics.suggestionCount, run.summary.suggestions.count)
        XCTAssertEqual(run.metrics.actionDraftCount, run.summary.actionDrafts.count)
    }

    func testActionDraftsPrepareForConfirmation() async throws {
        let run = try await measuredFallbackRun()
        let preparer = DraftOnlyToolActionPreparer()
        var prepared: [PreparedToolAction] = []

        for draft in run.summary.actionDrafts {
            try prepared.append(await preparer.prepare(draft))
        }

        XCTAssertFalse(prepared.isEmpty)
        XCTAssertTrue(prepared.contains { $0.state == .readyForConfirmation })
        XCTAssertTrue(prepared.allSatisfy { !$0.confirmationMessage.isEmpty })
    }

    func testMetricDistributionComputesPercentiles() {
        let distribution = MetricDistribution(samples: [1, 3, 5, 7, 9])
        XCTAssertEqual(distribution.count, 5)
        XCTAssertEqual(distribution.minimum, 1)
        XCTAssertEqual(distribution.maximum, 9)
        XCTAssertEqual(distribution.p50, 5)
        XCTAssertEqual(distribution.p95, 9)
    }

    func testRunHistoryStorePersistsAndAggregates() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalAssist-\(UUID().uuidString)")
            .appendingPathComponent("history.json")
        let store = RunHistoryStore(fileURL: url, limit: 3)

        try await store.append(sampleRun(index: 1, latency: 1))
        try await store.append(sampleRun(index: 2, latency: 3))
        try await store.append(sampleRun(index: 3, latency: 5))
        try await store.append(sampleRun(index: 4, latency: 9))

        let runs = try await store.load()
        let aggregate = try await store.aggregate()
        try await store.clear()

        XCTAssertEqual(runs.count, 3)
        XCTAssertEqual(runs.first?.summary.overview, "Run 4")
        XCTAssertEqual(aggregate.runCount, 3)
        XCTAssertEqual(aggregate.fallbackRuns, 3)
        XCTAssertEqual(aggregate.latencyMilliseconds.p50, 5)
    }

    func testLegacyHistoryPayloadStillDecodes() throws {
        // Availability shape from before the typed error taxonomy.
        let legacyJSON = """
        {"unavailable":{"reason":"device not eligible"}}
        """
        let decoded = try JSONDecoder().decode(ModelAvailability.self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(decoded.unavailability?.reason, .other)
        XCTAssertEqual(decoded.unavailability?.detail, "device not eligible")
    }

    // MARK: - Due-date parsing

    func testDueDateParserResolvesCommonHints() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parser = DueDateParser(calendar: calendar)
        // Wednesday 2026-07-01 12:00 UTC
        let now = Date(timeIntervalSince1970: 1_782_907_200)

        let friday = try XCTUnwrap(parser.date(from: "by Friday", relativeTo: now))
        XCTAssertEqual(calendar.component(.weekday, from: friday), 6)
        XCTAssertTrue(friday > now)

        let tomorrow = try XCTUnwrap(parser.date(from: "tomorrow", relativeTo: now))
        XCTAssertEqual(calendar.dateComponents([.day], from: now, to: tomorrow).day, 0)
        XCTAssertEqual(calendar.component(.hour, from: tomorrow), 9)

        let nextWeek = try XCTUnwrap(parser.date(from: "next week", relativeTo: now))
        XCTAssertEqual(calendar.component(.weekday, from: nextWeek), 2)

        let asap = try XCTUnwrap(parser.date(from: "asap", relativeTo: now))
        XCTAssertEqual(asap.timeIntervalSince(now), 2 * 3600, accuracy: 1)

        let iso = try XCTUnwrap(parser.date(from: "by 2026-07-04", relativeTo: now))
        XCTAssertEqual(calendar.component(.day, from: iso), 4)
        XCTAssertEqual(calendar.component(.hour, from: iso), 17)

        let monthName = try XCTUnwrap(parser.date(from: "before July 5", relativeTo: now))
        XCTAssertEqual(calendar.component(.month, from: monthName), 7)
        XCTAssertEqual(calendar.component(.day, from: monthName), 5)

        XCTAssertNil(parser.date(from: nil, relativeTo: now))
        XCTAssertNil(parser.date(from: "someday maybe", relativeTo: now))
    }

    func testBareDueDatesUseTheLocalCalendarDay() throws {
        // A bare model date like "2026-07-06" means that day where the user
        // is. Parsing it as GMT midnight shifted it into the previous local
        // day everywhere west of GMT.
        let parsed = try XCTUnwrap(LocalAssistDates.parse("2026-07-06"))
        let components = Calendar.current.dateComponents([.year, .month, .day], from: parsed)
        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 7)
        XCTAssertEqual(components.day, 6)
        XCTAssertEqual(LocalAssistDates.dateOnlyString(from: parsed), "2026-07-06")

        // Full timestamps still parse as instants.
        XCTAssertEqual(
            LocalAssistDates.parse("2026-07-01T12:00:00Z"),
            Date(timeIntervalSince1970: 1_782_907_200)
        )

        // Injectable-calendar call sites can pin an explicit zone.
        let tokyo = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        let tokyoParsed = try XCTUnwrap(LocalAssistDates.parse("2026-07-06", timeZone: tokyo))
        XCTAssertEqual(LocalAssistDates.dateOnlyString(from: tokyoParsed, timeZone: tokyo), "2026-07-06")
    }

    func testModelDueTodayTaskSurvivesNormalizationAndRoundtrip() throws {
        let today = LocalAssistDates.dateOnlyString(from: Date())
        let partial = StructuredSummaryPartial(
            overview: "Blockers are due today.",
            keyPoints: ["Send the blockers today"],
            suggestions: [
                TaskSuggestionPartial(
                    title: "Send Mira the blockers",
                    priority: .high,
                    dueHint: today,
                    action: .messageDraft,
                    rationale: "The deadline is explicit.",
                    confidence: 0.9
                ),
            ],
            isComplete: true
        )

        let summary = try XCTUnwrap(SummaryNormalizer().summary(
            from: partial,
            request: AssistantRequest(sourceText: "Send Mira the blockers today."),
            availability: .available
        ))

        let dueDate = try XCTUnwrap(summary.suggestions.first?.dueDate)
        XCTAssertTrue(
            Calendar.current.isDateInToday(dueDate),
            "a due-today model date must not be dropped as stale or shifted a day"
        )

        // Codable roundtrip through saved history keeps the calendar day.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(
            StructuredSummary.self,
            from: SummaryFormatter.jsonData(summary)
        )
        let decodedDue = try XCTUnwrap(decoded.suggestions.first?.dueDate)
        XCTAssertTrue(Calendar.current.isDateInToday(decodedDue))
    }

    func testNormalizerPrefersDeterministicDayNamesOverModelDates() throws {
        // The model resolved "by Wednesday" to a Tuesday; the title still
        // names the day, so the deterministic parser must correct it.
        let wrongModelDate = Calendar.current.date(byAdding: .day, value: 8, to: Date())
        let partial = StructuredSummaryPartial(
            overview: "Tax paperwork is due midweek.",
            keyPoints: ["The tax paperwork is due by Wednesday"],
            suggestions: [
                TaskSuggestionPartial(
                    title: "Finish the tax paperwork by Wednesday",
                    priority: .high,
                    dueDate: wrongModelDate
                ),
            ],
            isComplete: true
        )

        let summary = try XCTUnwrap(SummaryNormalizer().summary(
            from: partial,
            request: AssistantRequest(sourceText: "Finish the tax paperwork by Wednesday."),
            availability: .available
        ))

        let dueDate = try XCTUnwrap(summary.suggestions.first?.dueDate)
        XCTAssertEqual(
            Calendar.current.component(.weekday, from: dueDate), 4,
            "a title naming Wednesday must resolve to an actual Wednesday"
        )
    }

    func testInputKindInferenceClassifiesWithoutUserChoice() {
        XCTAssertEqual(
            AssistantInputKind.inferred(from: "Standup notes: infra is blocked, Priya shares the runbook, book a war room Thursday."),
            .meeting
        )
        XCTAssertEqual(
            AssistantInputKind.inferred(from: "Pay the electricity bill and book a dentist appointment tomorrow."),
            .personalAdmin
        )
        XCTAssertEqual(
            AssistantInputKind.inferred(from: "Ship the hotfix build tonight and confirm the rollout with Dana."),
            .note
        )
    }

    func testValidatorPreservesRefinementFlag() throws {
        let validated = try RequestValidator().validate(
            AssistantRequest(sourceText: " only keep urgent tasks ", isRefinement: true)
        )

        XCTAssertTrue(validated.isRefinement)
        XCTAssertEqual(validated.sourceText, "only keep urgent tasks")
    }

    func testFallbackLatencyMetric() {
        measure(metrics: [XCTClockMetric()]) {
            let expectation = expectation(description: "fallback completes")
            Task {
                do {
                    let fallback = DeterministicFallbackGenerator(clock: .frozen)
                    let service = LocalAssistService(fallback: fallback)
                    _ = try await service.summarize(
                        AssistantRequest(sourceText: "Review the launch checklist and send blockers by Friday.")
                    )
                } catch {
                    XCTFail("fallback latency run threw \(error)")
                }
                expectation.fulfill()
            }
            wait(for: [expectation], timeout: 1)
        }
    }

    // MARK: - Tools & execution

    func testFreeSlotCalculatorFindsGaps() {
        let base = Date(timeIntervalSince1970: 1_782_900_000)
        let window = DateInterval(start: base, end: base.addingTimeInterval(4 * 3600))
        let busy = [
            DateInterval(start: base.addingTimeInterval(3600), duration: 3600),
        ]

        let free = FreeSlotCalculator.freeWindows(busy: busy, within: window, minimumMinutes: 30)

        XCTAssertEqual(free.count, 2)
        XCTAssertEqual(free[0], DateInterval(start: base, duration: 3600))
        XCTAssertEqual(free[1].start, base.addingTimeInterval(2 * 3600))
    }

    func testCalendarToolReportsFreeWindowsAndCountsInvocation() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_782_907_200)
        let counter = ToolInvocationCounter()

        let friday = try XCTUnwrap(DueDateParser(calendar: calendar).date(from: "friday", relativeTo: now))
        let busyStart = try XCTUnwrap(calendar.date(bySettingHour: 9, minute: 0, second: 0, of: friday))
        let tool = CalendarAvailabilityTool(
            provider: StaticFreeBusyProvider(intervals: [DateInterval(start: busyStart, duration: 3600)]),
            counter: counter,
            calendar: calendar,
            now: { now }
        )

        let output = try await tool.call(arguments: .init(dayHint: "Friday"))

        XCTAssertTrue(output.contains("Free calendar windows"), output)
        let count = await counter.count
        XCTAssertEqual(count, 1)
    }

    func testContactsToolResolvesKnownPerson() async throws {
        let tool = ContactsLookupTool(
            resolver: StaticContactResolver(contacts: [
                ResolvedContact(displayName: "Mira Chen", hasEmail: true, hasPhone: false),
            ])
        )

        let found = try await tool.call(arguments: .init(personName: "Mira"))
        XCTAssertTrue(found.contains("Mira Chen"), found)
        XCTAssertTrue(found.contains("email"), found)

        let missing = try await tool.call(arguments: .init(personName: "Zoe"))
        XCTAssertTrue(missing.contains("No contact named"), missing)
    }

    func testSystemActionExecutorWritesReminderWithParsedDueDate() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_782_907_200)
        let store = RecordingWriteStore()
        let executor = SystemActionExecutor(store: store, calendar: calendar, now: { now })

        let draft = ToolActionDraft(
            kind: .reminder,
            title: "Create reminder",
            payload: ["title": "Send Mira the blockers", "notes": "From notes", "dueHint": "Friday"]
        )
        let prepared = try await DraftOnlyToolActionPreparer().prepare(draft)
        let executed = try await executor.execute(prepared)

        XCTAssertTrue(executed.didWriteToSystem)
        let reminders = await store.reminders
        XCTAssertEqual(reminders.count, 1)
        XCTAssertEqual(reminders.first?.title, "Send Mira the blockers")
        let due = try XCTUnwrap(reminders.first?.due)
        XCTAssertEqual(calendar.component(.weekday, from: due), 6)
    }

    func testSystemActionExecutorCreatesCalendarHold() async throws {
        let store = RecordingWriteStore()
        let executor = SystemActionExecutor(store: store)

        let draft = ToolActionDraft(
            kind: .calendarHold,
            title: "Draft calendar hold",
            payload: ["title": "Design sync", "duration": "30m", "dateHint": "next week"]
        )
        let prepared = try await DraftOnlyToolActionPreparer().prepare(draft)
        let executed = try await executor.execute(prepared)

        XCTAssertTrue(executed.didWriteToSystem)
        let holds = await store.holds
        XCTAssertEqual(holds.count, 1)
        XCTAssertEqual(holds.first?.durationMinutes, 30)
    }

    // MARK: - Conversation memory

    func testConversationMemoryKeepsRollingWindowAndCondenses() async throws {
        var memory = ConversationMemory(maxExchanges: 2)
        let service = LocalAssistService()

        for index in 1 ... 3 {
            let request = AssistantRequest(sourceText: "Review item \(index) and follow up tomorrow.")
            let summary = try await service.summarize(request)
            memory.record(request: request, summary: summary)
        }

        XCTAssertEqual(memory.exchanges.count, 2)
        XCTAssertTrue(memory.exchanges.first?.inputExcerpt.contains("item 2") == true)

        let condensed = try XCTUnwrap(memory.condensedContext())
        XCTAssertTrue(condensed.contains("Earlier in this conversation"))
        XCTAssertTrue(condensed.contains("Tasks:"))
    }

    // MARK: - Eval harness

    func testEvalScorerGivesPerfectScoreForReferenceSummary() {
        let evalCase = EvalCase(
            id: "unit",
            input: "Send Mira blockers by Friday.",
            expectedTasks: [.init(keywords: ["send", "mira"], dueHintContains: "friday", action: .messageDraft)],
            forbiddenPhrases: ["quarterly report"]
        )
        let summary = SummaryNormalizer().summary(
            from: .mira,
            request: AssistantRequest(sourceText: evalCase.input),
            availability: .available
        )!

        let result = EvalScorer.score(summary: summary, against: evalCase, latencyMilliseconds: 5)

        XCTAssertEqual(result.composite, 1.0, accuracy: 0.0001)
        XCTAssertEqual(result.taskRecall, 1.0)
        XCTAssertTrue(result.notes.isEmpty, result.notes.joined(separator: "; "))
    }

    func testEvalScorerPenalizesMissedTasksAndHallucinations() {
        let evalCase = EvalCase(
            id: "unit-miss",
            input: "Send Mira blockers by Friday.",
            expectedTasks: [
                .init(keywords: ["send", "mira"]),
                .init(keywords: ["schedule", "offsite"]),
            ],
            forbiddenPhrases: ["blockers"]
        )
        let summary = SummaryNormalizer().summary(
            from: .mira,
            request: AssistantRequest(sourceText: evalCase.input),
            availability: .available
        )!

        let result = EvalScorer.score(summary: summary, against: evalCase, latencyMilliseconds: 5)

        XCTAssertEqual(result.taskRecall, 0.5)
        XCTAssertEqual(result.hallucinationFree, 0.0)
        XCTAssertLessThan(result.composite, 0.9)
    }

    func testEvalRunnerScoresFallbackPipelineAboveThreshold() async throws {
        let report = try await EvalRunner.run(
            service: LocalAssistService(),
            configurationLabel: "unit-test"
        )

        XCTAssertEqual(report.caseResults.count, EvalDataset.standard.count)
        XCTAssertGreaterThanOrEqual(report.meanComposite, 0.75, report.renderedMarkdown())
    }

    // MARK: - Chunking & completion

    func testTranscriptChunkerSplitsOnSentenceBoundaries() {
        let text = Array(repeating: "Review the launch checklist before Friday.", count: 12)
            .joined(separator: " ")
        let chunks = TranscriptChunker.chunks(from: text, targetCharacters: 120)

        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 130 })
        XCTAssertTrue(chunks.allSatisfy { $0.hasSuffix(".") })
    }

    func testLongInputUsesMapReduceWithModel() async throws {
        let service = LocalAssistService(
            model: StaticStructuredModelClient.completing(with: .mira),
            chunkTargetCharacters: 80
        )
        let longText = Array(repeating: "Send Mira the blockers by Friday.", count: 10)
            .joined(separator: " ")

        var sectionMessages = 0
        var summary: StructuredSummary?
        for try await update in service.streamSummary(AssistantRequest(sourceText: longText)) {
            if update.message?.contains("Summarizing section") == true {
                sectionMessages += 1
            }
            if let final = update.summary {
                summary = final
            }
        }

        XCTAssertGreaterThan(sectionMessages, 1, "expected per-section progress messages")
        XCTAssertEqual(summary?.source, .foundationModels)
    }

    func testLongInputMergesDeterministicallyWithoutModel() async throws {
        let service = LocalAssistService(chunkTargetCharacters: 80)
        let longText = Array(repeating: "Review the launch checklist and send blockers by Friday.", count: 8)
            .joined(separator: " ")

        let summary = try await service.summarize(AssistantRequest(sourceText: longText))

        XCTAssertEqual(summary.source, .deterministicFallback)
        XCTAssertTrue(summary.headline.contains("more sections"), summary.headline)
        XCTAssertFalse(summary.tasks.isEmpty)
    }

    func testChunkerHandlesDegenerateInput() {
        XCTAssertEqual(TranscriptChunker.chunks(from: ""), [])
        XCTAssertFalse(TranscriptChunker.chunks(from: "   \n  ").isEmpty)
        XCTAssertEqual(TranscriptChunker.digest(of: []), "")
    }

    func testNormalizerRejectsEmptyPartial() {
        XCTAssertNil(SummaryNormalizer().summary(
            from: StructuredSummaryPartial(),
            request: AssistantRequest(sourceText: "anything"),
            availability: .available
        ))
    }

    func testTaskCompletionPersistsThroughHistoryStore() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalAssist-\(UUID().uuidString)")
            .appendingPathComponent("history.json")
        let store = RunHistoryStore(fileURL: url, limit: 5)

        let run = sampleRun(index: 1, latency: 1)
        let taskID = run.summary.tasks[0].id
        try await store.append(run)

        var runs = try await store.setTask(taskID, completed: true, inRun: run.id)
        XCTAssertTrue(runs.first?.isCompleted(run.summary.tasks[0]) == true)

        // Survives reload from disk.
        runs = try await store.load()
        XCTAssertTrue(runs.first?.completedTaskIDs.contains(taskID) == true)

        runs = try await store.setTask(taskID, completed: false, inRun: run.id)
        XCTAssertFalse(runs.first?.isCompleted(run.summary.tasks[0]) == true)
        try await store.clear()
    }

    // MARK: - Morning brief

    func testMorningBriefBodyReflectsDueAndCapturedCounts() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let briefDay = GenerationClock.frozenReferenceDate
        let yesterday = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: briefDay))

        var dueRun = sampleRun(index: 1, latency: 1)
        dueRun.summary.suggestions[0].dueDate = briefDay
        dueRun.summary.generatedAt = yesterday

        let emptyBody = MorningBriefScheduler.briefBody(history: [], briefDay: briefDay, calendar: calendar)
        XCTAssertTrue(emptyBody.contains("clear morning"), emptyBody)

        let body = MorningBriefScheduler.briefBody(history: [dueRun], briefDay: briefDay, calendar: calendar)
        XCTAssertTrue(body.contains("1 due today"), body)
        XCTAssertTrue(body.contains("1 captured yesterday"), body)
    }
}

// MARK: - Fixtures

private extension StructuredSummaryPartial {
    static let mira = StructuredSummaryPartial(
        overview: "Mira needs launch blockers and a design sync.",
        keyPoints: ["Send Mira blockers", "Schedule a design sync"],
        suggestions: [
            TaskSuggestionPartial(
                title: "Send Mira blockers",
                priority: .high,
                dueHint: "Friday",
                action: .messageDraft,
                rationale: "A direct follow-up message is needed.",
                confidence: 0.91
            ),
        ],
        isComplete: true
    )

    static let launchSync = StructuredSummaryPartial(
        overview: "A launch sync needs a calendar hold.",
        keyPoints: ["Schedule the launch sync", "Share the agenda"],
        suggestions: [
            TaskSuggestionPartial(
                title: "Schedule launch sync",
                priority: .medium,
                dueHint: "next week",
                action: .calendarHold,
                rationale: "The team needs time reserved for launch coordination.",
                confidence: 0.84
            ),
        ],
        isComplete: true
    )
}

private func measuredFallbackRun() async throws -> AssistantRun {
    let service = LocalAssistService()
    return try await service.summarizeWithMetrics(
        AssistantRequest(
            sourceText: "Review the launch checklist and send blockers by Friday.",
            maxSuggestions: 3
        )
    )
}

private func sampleRun(index: Int, latency: Double) -> AssistantRun {
    let suggestion = TaskSuggestion(
        id: "task-\(index)",
        title: "Run \(index)",
        priority: .medium,
        dueHint: nil,
        action: .reminder,
        rationale: "Test run",
        confidence: 0.8
    )
    let draft = ToolActionPlanner().draft(for: suggestion)
    let summary = StructuredSummary(
        overview: "Run \(index)",
        keyPoints: ["Point \(index)"],
        suggestions: [suggestion],
        actionDrafts: [draft],
        source: .deterministicFallback,
        diagnostics: GenerationDiagnostics(
            availability: .unavailable(ModelUnavailability(reason: .forcedOffline, detail: "test")),
            fallbackReason: "test"
        )
    )
    return AssistantRun(
        request: AssistantRequest(sourceText: "Run \(index)"),
        summary: summary,
        metrics: RunMetrics(
            startedAt: Date(timeIntervalSince1970: Double(index)),
            finishedAt: Date(timeIntervalSince1970: Double(index) + latency / 1000),
            durationMilliseconds: latency,
            source: .deterministicFallback,
            suggestionCount: 1,
            actionDraftCount: 1,
            keyPointCount: 1,
            inputCharacterCount: 8,
            outputByteCount: 64,
            fallbackReason: "test"
        )
    )
}
