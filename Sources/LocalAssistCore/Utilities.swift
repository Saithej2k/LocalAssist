import Foundation

enum OrderedUnique {
    static func values(_ input: [String]) -> [String] {
        var seen = Set<String>()
        var output: [String] = []

        for value in input {
            let key = value.lowercased()
            guard seen.insert(key).inserted else {
                continue
            }
            output.append(value)
        }

        return output
    }
}

enum StableID {
    static func make(from text: String) -> String {
        let slug = text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .prefix(5)
            .joined(separator: "-")

        let readableSlug = slug.isEmpty ? "task" : slug
        return "\(readableSlug)-\(fnv1a(text))"
    }

    private static func fnv1a(_ text: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}

extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }

    func normalizedWhitespace() -> String {
        components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    func cleanedBullet() -> String {
        trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-*• "))
            .normalizedWhitespace()
    }

    func removingLeadingTaskMarker() -> String {
        var value = self
        let markers = ["please ", "todo ", "to-do ", "task "]
        for marker in markers where value.lowercased().hasPrefix(marker) {
            value.removeFirst(marker.count)
            break
        }
        return value.cleanedBullet()
    }

    func sentenceCapitalized() -> String {
        guard let first else {
            return self
        }
        return first.uppercased() + dropFirst()
    }
}
