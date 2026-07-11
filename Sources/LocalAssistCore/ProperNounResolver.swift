import Foundation

/// Post-final correction of misrecognized proper names against the user's
/// known local contacts — the "mirror" that should have been "Mira".
///
/// Evidence, never guessing:
/// - **Phonetic**: a consonant-skeleton key (vowels dropped, repeats
///   collapsed) matches "mirror" to "mira" and "prya" to "priya" without a
///   full phonetic algorithm's false positives.
/// - **Edit distance**: normalized similarity guards the phonetic key
///   against short-key collisions.
/// - **Recognizer confidence**: a high-confidence token demands stronger
///   string evidence before it is second-guessed.
///
/// When more than one contact is plausible the resolver reports the
/// ambiguity and changes nothing — a silently wrong name in a message
/// draft is the worst outcome available.
public struct ProperNounResolver: Sendable {
    public enum Resolution: Equatable, Sendable {
        /// No contact is plausible; the token stands.
        case unchanged
        /// Exactly one contact is plausible.
        case corrected(String)
        /// Multiple contacts are plausible; the caller must ask, not guess.
        case ambiguous([String])
    }

    /// A correction the transcript pass applied or declined, by token.
    public struct TokenResolution: Equatable, Sendable {
        public var token: String
        public var resolution: Resolution
    }

    /// First names (or full names) of known local contacts. Matching uses
    /// the first word of each entry — commands address people by first name.
    private let contactFirstNames: [String]

    /// Tokens at or above this recognizer confidence need combined
    /// phonetic + similarity evidence; below it, phonetic evidence alone
    /// may correct.
    private let highConfidenceThreshold: Double

    /// Minimum normalized similarity (1 - distance/maxLength) for a
    /// candidate to stay plausible.
    private let minimumSimilarity: Double

    public init(
        contactNames: [String],
        highConfidenceThreshold: Double = 0.9,
        minimumSimilarity: Double = 0.4
    ) {
        contactFirstNames = contactNames
            .compactMap { $0.components(separatedBy: .whitespaces).first }
            .filter { !$0.isEmpty }
        self.highConfidenceThreshold = highConfidenceThreshold
        self.minimumSimilarity = minimumSimilarity
    }

    /// Resolves one token against the known contacts.
    public func resolve(token: String, confidence: Double? = nil) -> Resolution {
        let lowered = token.lowercased().trimmingCharacters(in: .punctuationCharacters)
        guard lowered.count >= 2 else {
            return .unchanged
        }
        // Already a known name — nothing to correct.
        if contactFirstNames.contains(where: { $0.lowercased() == lowered }) {
            return .unchanged
        }

        let tokenSkeleton = Self.consonantSkeleton(lowered)
        let demandsStrongEvidence = (confidence ?? 0) >= highConfidenceThreshold

        var candidates: [String] = []
        for contact in contactFirstNames {
            let contactLowered = contact.lowercased()
            let similarity = Self.similarity(lowered, contactLowered)
            let phoneticMatch = !tokenSkeleton.isEmpty
                && tokenSkeleton == Self.consonantSkeleton(contactLowered)

            let plausible: Bool = if demandsStrongEvidence {
                // The recognizer is confident: both signals must agree, and
                // the string evidence must be stronger than the floor.
                phoneticMatch && similarity >= max(minimumSimilarity, 0.5)
            } else {
                phoneticMatch && similarity >= minimumSimilarity
            }
            if plausible {
                candidates.append(contact)
            }
        }

        switch candidates.count {
        case 0:
            return .unchanged
        case 1:
            return .corrected(candidates[0])
        default:
            return .ambiguous(candidates.sorted())
        }
    }

    /// Applies single-candidate corrections across a final transcript.
    /// Ambiguous tokens are reported but left untouched.
    public func resolveTranscript(
        _ text: String,
        confidence: Double? = nil
    ) -> (text: String, resolutions: [TokenResolution]) {
        var resolutions: [TokenResolution] = []
        let corrected = text
            .components(separatedBy: " ")
            .map { word -> String in
                let core = word.trimmingCharacters(in: .punctuationCharacters)
                guard !core.isEmpty else {
                    return word
                }
                let resolution = resolve(token: core, confidence: confidence)
                switch resolution {
                case .unchanged:
                    return word
                case .corrected(let name):
                    resolutions.append(TokenResolution(token: core, resolution: resolution))
                    return word.replacingOccurrences(of: core, with: name)
                case .ambiguous:
                    resolutions.append(TokenResolution(token: core, resolution: resolution))
                    return word
                }
            }
            .joined(separator: " ")
        return (corrected, resolutions)
    }

    // MARK: - Evidence

    /// Vowels (and near-vowels h/w/y) dropped, adjacent repeats collapsed:
    /// "mirror" → "mr", "mira" → "mr", "priya" → "pr". Deliberately cruder
    /// than Soundex — strict Soundex keeps repeated consonants separated by
    /// vowels ("mirror" M660 vs "mira" M600) and misses exactly the ASR
    /// confusion this exists to catch.
    static func consonantSkeleton(_ word: String) -> String {
        var output: [Character] = []
        for character in word.lowercased() where character.isLetter {
            if "aeiouhwy".contains(character) {
                continue
            }
            if output.last == character {
                continue
            }
            output.append(character)
        }
        return String(output)
    }

    /// 1 − levenshtein/maxLength, in 0...1.
    static func similarity(_ lhs: String, _ rhs: String) -> Double {
        let longest = max(lhs.count, rhs.count)
        guard longest > 0 else {
            return 1
        }
        return 1 - Double(levenshtein(lhs, rhs)) / Double(longest)
    }

    static func levenshtein(_ lhs: String, _ rhs: String) -> Int {
        let lhsChars = Array(lhs)
        let rhsChars = Array(rhs)
        guard !lhsChars.isEmpty else {
            return rhsChars.count
        }
        guard !rhsChars.isEmpty else {
            return lhsChars.count
        }

        var previous = Array(0 ... rhsChars.count)
        var current = [Int](repeating: 0, count: rhsChars.count + 1)
        for row in 1 ... lhsChars.count {
            current[0] = row
            for column in 1 ... rhsChars.count {
                let cost = lhsChars[row - 1] == rhsChars[column - 1] ? 0 : 1
                current[column] = min(
                    previous[column] + 1,
                    current[column - 1] + 1,
                    previous[column - 1] + cost
                )
            }
            swap(&previous, &current)
        }
        return previous[rhsChars.count]
    }
}
