import Foundation
import XCTest
import LocalAssistAppUI
@testable import LocalAssistCore

/// Communication routing: which composer a draft opens (Messages vs mail),
/// who it's addressed to, and which drafts outrank the rest.
final class LocalAssistMessageRoutingTests: XCTestCase {
    // MARK: - Channel from the title verb

    func testExplicitVerbsPickTheirChannel() {
        XCTAssertEqual(MessageChannelRouter.explicitChannel(forTitle: "Text Priya about Sunday brunch"), .textMessage)
        XCTAssertEqual(MessageChannelRouter.explicitChannel(forTitle: "Message John when the deck ships"), .textMessage)
        XCTAssertEqual(MessageChannelRouter.explicitChannel(forTitle: "Email the landlord about the heater"), .email)
        XCTAssertEqual(MessageChannelRouter.explicitChannel(forTitle: "Send Mira the blockers"), .auto)
        // "context" must not read as a text verb.
        XCTAssertEqual(MessageChannelRouter.explicitChannel(forTitle: "Share more context with the team"), .auto)
    }

    func testRecipientExtraction() {
        XCTAssertEqual(MessageChannelRouter.recipientName(fromTitle: "Text Priya about Sunday brunch"), "Priya")
        XCTAssertEqual(MessageChannelRouter.recipientName(fromTitle: "Email the landlord about the heater"), "landlord")
        XCTAssertEqual(MessageChannelRouter.recipientName(fromTitle: "Message John Smith about the deck"), "John Smith")
        XCTAssertEqual(MessageChannelRouter.recipientName(fromTitle: "text mom tonight"), "mom")
        XCTAssertNil(MessageChannelRouter.recipientName(fromTitle: "Pay the electricity bill"))
    }

    // MARK: - Personal vs work resolution

    func testAutoChannelFollowsThePersonalRule() {
        // Saved with a phone number → personal → Messages.
        XCTAssertEqual(MessageChannelRouter.resolve(explicit: .auto, hasPhone: true, hasEmail: true), .textMessage)
        // Email-only contact → work-shaped → mail.
        XCTAssertEqual(MessageChannelRouter.resolve(explicit: .auto, hasPhone: false, hasEmail: true), .email)
        // Unknown person → an unaddressed mail composer beats a text to nobody.
        XCTAssertEqual(MessageChannelRouter.resolve(explicit: .auto, hasPhone: false, hasEmail: false), .email)
        // Explicit verbs always win over the contact card.
        XCTAssertEqual(MessageChannelRouter.resolve(explicit: .textMessage, hasPhone: false, hasEmail: true), .textMessage)
        XCTAssertEqual(MessageChannelRouter.resolve(explicit: .email, hasPhone: true, hasEmail: false), .email)
    }

    // MARK: - Composer URLs

    func testTextMessageHandoffOpensMessagesWithNumberAndBody() throws {
        let url = try XCTUnwrap(MessageChannelRouter.handoffURL(
            channel: .textMessage,
            phone: "+1 (555) 010-2030",
            email: nil,
            subject: "Text Priya about Sunday brunch",
            body: "Sunday works — 11am?"
        ))
        XCTAssertEqual(url.scheme, "sms")
        XCTAssertTrue(url.absoluteString.hasPrefix("sms:+15550102030&body="))
        XCTAssertFalse(url.absoluteString.contains(" "), "sms body must be percent-encoded")
    }

    func testEmailHandoffCarriesAddressSubjectAndBody() throws {
        let url = try XCTUnwrap(MessageChannelRouter.handoffURL(
            channel: .email,
            phone: nil,
            email: "landlord@building.com",
            subject: "Broken heater",
            body: "The heater in 4B is still down."
        ))
        XCTAssertEqual(url.scheme, "mailto")
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.path, "landlord@building.com")
        XCTAssertEqual(components.queryItems?.first { $0.name == "subject" }?.value, "Broken heater")
        XCTAssertEqual(components.queryItems?.first { $0.name == "body" }?.value, "The heater in 4B is still down.")
    }

    @MainActor
    func testLegacyDraftsWithoutChannelStillOpenMailComposer() throws {
        // Histories recorded before channels existed have no channel or
        // recipient keys — they must keep opening the mail composer.
        let action = PreparedToolAction(
            id: "legacy",
            draft: ToolActionDraft(
                kind: .messageDraft,
                title: "Draft follow-up message",
                payload: ["subject": "Send Mira the blockers", "body": "Blockers list"]
            ),
            state: .readyForConfirmation,
            confirmationTitle: "Draft message",
            confirmationMessage: "Review before sending"
        )
        let url = try XCTUnwrap(LocalAssistViewModel.draftHandoffURL(for: action))
        XCTAssertEqual(url.scheme, "mailto")
    }

    @MainActor
    func testEnrichedTextDraftOpensMessages() throws {
        let action = PreparedToolAction(
            id: "text",
            draft: ToolActionDraft(
                kind: .messageDraft,
                title: "Draft text message",
                payload: [
                    "subject": "Text Priya about Sunday brunch",
                    "body": "Brunch?",
                    "channel": "sms",
                    "recipient": "Priya",
                    "recipientPhone": "+15550102030",
                ]
            ),
            state: .readyForConfirmation,
            confirmationTitle: "Draft message",
            confirmationMessage: "Review before sending"
        )
        let url = try XCTUnwrap(LocalAssistViewModel.draftHandoffURL(for: action))
        XCTAssertEqual(url.scheme, "sms")
        XCTAssertTrue(url.absoluteString.contains("+15550102030"))
    }

    // MARK: - Planner payload

    func testPlannerStampsChannelAndRecipientOnMessageDrafts() {
        let planner = ToolActionPlanner()
        let draft = planner.draft(for: TaskSuggestion(
            id: "t1",
            title: "Text Priya about Sunday brunch",
            priority: .medium,
            dueHint: nil,
            action: .messageDraft,
            rationale: "Confirm the plan.",
            confidence: 0.9
        ))
        XCTAssertEqual(draft.payload["channel"], "sms")
        XCTAssertEqual(draft.payload["recipient"], "Priya")
        XCTAssertEqual(draft.title, "Draft text message")

        let emailDraft = planner.draft(for: TaskSuggestion(
            id: "t2",
            title: "Email the landlord about the heater",
            priority: .high,
            dueHint: nil,
            action: .messageDraft,
            rationale: "The heater is still broken.",
            confidence: 0.9
        ))
        XCTAssertEqual(emailDraft.payload["channel"], "email")
        XCTAssertEqual(emailDraft.payload["recipient"], "landlord")
    }

    // MARK: - Urgency

    func testUrgencyMatchesWholeWordsOnly() {
        let contacts = MessageChannelRouter.priorityContacts(fromSetting: "mom, dad, Anika Rao")
        XCTAssertTrue(MessageChannelRouter.isUrgent(text: "Text mom about dinner", priorityContacts: contacts))
        XCTAssertTrue(MessageChannelRouter.isUrgent(text: "Email Anika Rao the summary", priorityContacts: contacts))
        XCTAssertFalse(MessageChannelRouter.isUrgent(text: "Check the deadline for the moment", priorityContacts: contacts))
        XCTAssertFalse(MessageChannelRouter.isUrgent(text: "Text Priya", priorityContacts: []))
    }

    func testPriorityCommunicationsSortFirstAndGetFlagged() {
        func prepared(_ id: String, kind: SuggestedAction, subject: String) -> PreparedToolAction {
            PreparedToolAction(
                id: id,
                draft: ToolActionDraft(kind: kind, title: subject, payload: ["subject": subject]),
                state: .readyForConfirmation,
                confirmationTitle: subject,
                confirmationMessage: ""
            )
        }
        let actions = [
            prepared("1", kind: .reminder, subject: "Pay the electricity bill"),
            prepared("2", kind: .messageDraft, subject: "Text Priya about brunch"),
            prepared("3", kind: .messageDraft, subject: "Text mom about dinner"),
            prepared("4", kind: .reminder, subject: "Call dad tonight"),
        ]
        let sorted = MessageChannelRouter.prioritized(
            actions,
            priorityContacts: MessageChannelRouter.priorityContacts(fromSetting: "mom, dad")
        )
        XCTAssertEqual(sorted.map(\.id), ["3", "1", "2", "4"], "mom's text leads; a reminder is not a communication")
        XCTAssertEqual(sorted[0].draft.payload["priority"], "urgent")
        XCTAssertNil(sorted[1].draft.payload["priority"])
    }
}
