import Foundation
import LocalAssistCore

#if canImport(EventKit)
    import EventKit

    public enum SystemAccessError: Error, Equatable, Sendable, CustomStringConvertible {
        case calendarAccessDenied
        case remindersAccessDenied
        case contactsAccessDenied

        public var description: String {
            switch self {
            case .calendarAccessDenied:
                "Calendar access was denied. Grant access in Settings to ground suggestions in real availability."
            case .remindersAccessDenied:
                "Reminders access was denied. Grant access in Settings to create confirmed reminders."
            case .contactsAccessDenied:
                "Contacts access was denied. Grant access in Settings to resolve people in notes."
            }
        }
    }

    /// Live EventKit-backed open-reminder lookup. Same access pattern as the
    /// free/busy provider: reminders permission is requested on the first
    /// tool call, and a denial surfaces as a typed error the service treats
    /// as a tool failure — never a crash.
    public final class EventKitReminderProvider: ReminderLookupProviding, @unchecked Sendable {
        private let store = EKEventStore()

        public init() {}

        public func openReminders() async throws -> [OpenReminder] {
            guard try await store.requestFullAccessToReminders() else {
                throw SystemAccessError.remindersAccessDenied
            }

            let predicate = store.predicateForIncompleteReminders(
                withDueDateStarting: nil,
                ending: nil,
                calendars: nil
            )
            // EKReminder is not Sendable, so the mapping happens inside the
            // fetch callback and only the value-type results cross the
            // continuation boundary.
            return await withCheckedContinuation { continuation in
                store.fetchReminders(matching: predicate) { fetched in
                    let open = (fetched ?? []).compactMap { reminder -> OpenReminder? in
                        guard let title = reminder.title, !title.isEmpty else {
                            return nil
                        }
                        return OpenReminder(
                            title: title,
                            dueDate: reminder.dueDateComponents.flatMap { Calendar.current.date(from: $0) }
                        )
                    }
                    continuation.resume(returning: open)
                }
            }
        }
    }

    /// Live EventKit-backed free/busy lookup. `EKEventStore` is documented
    /// thread-safe, hence the `@unchecked Sendable` wrapper.
    public final class EventKitFreeBusyProvider: FreeBusyProviding, @unchecked Sendable {
        private let store = EKEventStore()

        public init() {}

        public func busyIntervals(from start: Date, to end: Date) async throws -> [DateInterval] {
            guard try await store.requestFullAccessToEvents() else {
                throw SystemAccessError.calendarAccessDenied
            }

            let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
            return store.events(matching: predicate)
                .filter { !$0.isAllDay }
                .compactMap { event in
                    guard let eventStart = event.startDate, let eventEnd = event.endDate,
                          eventEnd > eventStart
                    else {
                        return nil
                    }
                    return DateInterval(start: eventStart, end: eventEnd)
                }
        }
    }
#endif

#if canImport(Contacts)
    import Contacts

    public final class ContactsFrameworkResolver: ContactResolving, @unchecked Sendable {
        private let store = CNContactStore()

        public init() {}

        public func contacts(matching name: String) async throws -> [ResolvedContact] {
            let granted = try await store.requestAccess(for: .contacts)
            guard granted else {
                throw SystemAccessError.contactsAccessDenied
            }

            let keys: [CNKeyDescriptor] = [
                CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
                CNContactEmailAddressesKey as CNKeyDescriptor,
                CNContactPhoneNumbersKey as CNKeyDescriptor,
            ]
            let predicate = CNContact.predicateForContacts(matchingName: name)
            let contacts = try store.unifiedContacts(matching: predicate, keysToFetch: keys)

            return contacts.map { contact in
                ResolvedContact(
                    displayName: CNContactFormatter.string(from: contact, style: .fullName)
                        ?? name,
                    hasEmail: !contact.emailAddresses.isEmpty,
                    hasPhone: !contact.phoneNumbers.isEmpty,
                    emailAddress: contact.emailAddresses.first.map { String($0.value) },
                    phoneNumber: contact.phoneNumbers.first?.value.stringValue
                )
            }
        }
    }
#endif
