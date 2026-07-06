import Foundation
#if canImport(AVFoundation)
    import AVFoundation
#endif

/// Reads a brief aloud with the system's on-device voices — commute/AirPods
/// companion to the morning brief. Speech synthesis never leaves the device.
@MainActor
public final class BriefSpeaker: NSObject, ObservableObject {
    @Published public private(set) var isSpeaking = false

    #if canImport(AVFoundation)
        private let synthesizer = AVSpeechSynthesizer()
    #endif

    override public init() {
        super.init()
        #if canImport(AVFoundation)
            synthesizer.delegate = self
        #endif
    }

    public func toggle(text: String) {
        if isSpeaking {
            stop()
        } else {
            speak(text)
        }
    }

    public func speak(_ text: String) {
        guard !text.isEmpty else {
            return
        }
        #if canImport(AVFoundation)
            let utterance = AVSpeechUtterance(string: text)
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate
            synthesizer.speak(utterance)
            isSpeaking = true
        #endif
    }

    public func stop() {
        #if canImport(AVFoundation)
            synthesizer.stopSpeaking(at: .immediate)
        #endif
        isSpeaking = false
    }

    public static func spokenText(for summary: StructuredSummaryLike) -> String {
        var parts: [String] = [summary.spokenHeadline]
        if !summary.spokenKeyPoints.isEmpty {
            parts.append("Key points: " + summary.spokenKeyPoints.joined(separator: ". "))
        }
        if !summary.spokenTasks.isEmpty {
            parts.append("Tasks: " + summary.spokenTasks.joined(separator: ". "))
        }
        return parts.joined(separator: ". ")
    }
}

/// Small seam so the spoken-text builder is testable without AVFoundation.
public protocol StructuredSummaryLike {
    var spokenHeadline: String { get }
    var spokenKeyPoints: [String] { get }
    var spokenTasks: [String] { get }
}

#if canImport(AVFoundation)
    extension BriefSpeaker: AVSpeechSynthesizerDelegate {
        public nonisolated func speechSynthesizer(_: AVSpeechSynthesizer, didFinish _: AVSpeechUtterance) {
            Task { @MainActor in
                self.isSpeaking = false
            }
        }

        public nonisolated func speechSynthesizer(_: AVSpeechSynthesizer, didCancel _: AVSpeechUtterance) {
            Task { @MainActor in
                self.isSpeaking = false
            }
        }
    }
#endif

import LocalAssistCore

extension StructuredSummary: StructuredSummaryLike {
    public var spokenHeadline: String { headline }
    public var spokenKeyPoints: [String] { keyPoints }
    public var spokenTasks: [String] {
        tasks.map { task in
            var line = task.title
            if let due = task.dueHint ?? task.iso8601DueDate {
                line += ", due \(due)"
            }
            return line
        }
    }
}
