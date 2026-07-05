import Foundation
import FoundationModels
import LocalAssistCore

public struct ResolvedContact: Equatable, Sendable {
    public var displayName: String
    public var hasEmail: Bool
    public var hasPhone: Bool

    public init(displayName: String, hasEmail: Bool, hasPhone: Bool) {
        self.displayName = displayName
        self.hasEmail = hasEmail
        self.hasPhone = hasPhone
    }
}

public protocol ContactResolving: Sendable {
    func contacts(matching name: String) async throws -> [ResolvedContact]
}

public struct StaticContactResolver: ContactResolving {
    public var contacts: [ResolvedContact]

    public init(contacts: [ResolvedContact] = []) {
        self.contacts = contacts
    }

    public func contacts(matching name: String) async throws -> [ResolvedContact] {
        contacts.filter { $0.displayName.lowercased().contains(name.lowercased()) }
    }
}

/// Lets the model resolve first names in notes ("send Mira the blockers") to
/// real people, so message drafts and reminders reference an actual contact
/// instead of a guess.
public struct ContactsLookupTool: FoundationModels.Tool {
    public let name = "lookUpContact"
    public let description = """
    Looks up a person by name in the user's contacts and reports whether they \
    can be reached by email or phone. Call this when a note references a person \
    by first name.
    """

    @Generable(description: "Person to look up in the user's contacts.")
    public struct Arguments: Sendable {
        @Guide(description: "The person's name as written in the note, e.g. 'Mira'.")
        public var personName: String

        public init(personName: String) {
            self.personName = personName
        }
    }

    private let resolver: any ContactResolving
    private let counter: ToolInvocationCounter?

    public init(resolver: any ContactResolving, counter: ToolInvocationCounter? = nil) {
        self.resolver = resolver
        self.counter = counter
    }

    public func call(arguments: Arguments) async throws -> String {
        await counter?.increment()

        let matches = try await resolver.contacts(matching: arguments.personName)
        guard !matches.isEmpty else {
            return "No contact named '\(arguments.personName)' was found. Refer to them exactly as the note does."
        }

        let described = matches.prefix(3).map { contact in
            var channels: [String] = []
            if contact.hasEmail {
                channels.append("email")
            }
            if contact.hasPhone {
                channels.append("phone")
            }
            let reachable = channels.isEmpty ? "no contact methods" : channels.joined(separator: " and ")
            return "\(contact.displayName) (\(reachable) available)"
        }
        return "Matching contacts: \(described.joined(separator: "; "))."
    }
}
