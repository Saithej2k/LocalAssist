import OSLog

enum LocalAssistInstrumentation {
    static let subsystem = "com.saithej.localassist"

    static func generationSignposter() -> OSSignposter {
        OSSignposter(subsystem: subsystem, category: "Generation")
    }

    static func actionSignposter() -> OSSignposter {
        OSSignposter(subsystem: subsystem, category: "Actions")
    }

    static func historySignposter() -> OSSignposter {
        OSSignposter(subsystem: subsystem, category: "History")
    }
}
