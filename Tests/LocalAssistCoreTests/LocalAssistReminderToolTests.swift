import Foundation
import XCTest
@testable import LocalAssistCore
@testable import LocalAssistSystemTools

/// The read-only reminders lookup tool: static-provider filtering, output
/// formatting, and invocation counting, in the style of the calendar and
/// contacts tool tests.
final class LocalAssistReminderToolTests: XCTestCase {
    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    func testRemindersToolFiltersByTermAndCountsInvocation() async throws {
        let counter = ToolInvocationCounter()
        let due = utcCalendar.date(from: DateComponents(year: 2026, month: 7, day: 11))!
        let tool = RemindersLookupTool(
            provider: StaticReminderProvider(reminders: [
                OpenReminder(title: "Book the dentist", dueDate: due),
                OpenReminder(title: "Pick up groceries"),
            ]),
            counter: counter,
            calendar: utcCalendar
        )

        let output = try await tool.call(arguments: .init(searchTerm: "dentist"))

        XCTAssertTrue(output.contains("Book the dentist"), output)
        XCTAssertTrue(output.contains("due 2026-07-11"), output)
        XCTAssertFalse(output.contains("groceries"), "unmatched titles stay out of the answer")
        let count = await counter.count
        XCTAssertEqual(count, 1)
    }

    func testRemindersToolListsAllForEmptyTermDatedFirst() async throws {
        let sooner = utcCalendar.date(from: DateComponents(year: 2026, month: 7, day: 11))!
        let later = utcCalendar.date(from: DateComponents(year: 2026, month: 7, day: 20))!
        let tool = RemindersLookupTool(
            provider: StaticReminderProvider(reminders: [
                OpenReminder(title: "Renew car insurance", dueDate: later),
                OpenReminder(title: "Call the plumber"),
                OpenReminder(title: "Book the dentist", dueDate: sooner),
            ]),
            calendar: utcCalendar
        )

        let output = try await tool.call(arguments: .init(searchTerm: ""))

        // Dated reminders first, soonest first; undated ones trail.
        let dentist = try XCTUnwrap(output.range(of: "Book the dentist"))
        let insurance = try XCTUnwrap(output.range(of: "Renew car insurance"))
        let plumber = try XCTUnwrap(output.range(of: "Call the plumber"))
        XCTAssertTrue(dentist.lowerBound < insurance.lowerBound, output)
        XCTAssertTrue(insurance.lowerBound < plumber.lowerBound, output)
        XCTAssertTrue(output.contains("(no due date)"), output)
    }

    func testRemindersToolSaysSoWhenNothingMatchesOrExists() async throws {
        let some = RemindersLookupTool(
            provider: StaticReminderProvider(reminders: [OpenReminder(title: "Pick up groceries")]),
            calendar: utcCalendar
        )
        let noMatch = try await some.call(arguments: .init(searchTerm: "dentist"))
        XCTAssertTrue(noMatch.contains("No open reminders match 'dentist'"), noMatch)

        let empty = RemindersLookupTool(
            provider: StaticReminderProvider(),
            calendar: utcCalendar
        )
        let none = try await empty.call(arguments: .init(searchTerm: ""))
        XCTAssertTrue(none.contains("no open reminders"), none)
    }
}
