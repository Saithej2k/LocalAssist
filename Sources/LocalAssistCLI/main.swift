import Darwin
import Foundation
import LocalAssistCore
import LocalAssistFoundationModels

@main
struct LocalAssistCommand {
    static func main() async {
        do {
            let arguments = CommandArguments(CommandLine.arguments.dropFirst())
            if arguments.helpRequested {
                print(Self.usage)
                return
            }

            let input = try arguments.resolveInput()
            let request = AssistantRequest(
                sourceText: input,
                maxSuggestions: arguments.maxSuggestions
            )

            let service = arguments.forceFallback
                ? LocalAssistService()
                : LocalAssistLiveFactory.makeService()

            let summary = try await service.summarize(request)

            if arguments.plainText {
                print(SummaryFormatter.plainText(summary))
            } else {
                let data = try SummaryFormatter.jsonData(summary, prettyPrinted: true)
                print(String(decoding: data, as: UTF8.self))
            }
        } catch let failure as GenerationFailure {
            FileHandle.standardError.write(Data("localassist: \(failure.userMessage) (\(failure))\n".utf8))
            exit(1)
        } catch {
            FileHandle.standardError.write(Data("localassist: \(error)\n".utf8))
            exit(1)
        }
    }

    private static let usage = """
    LocalAssist

    USAGE:
      localassist --text "Call Mom tonight and pay the electricity bill by Friday"
      localassist --file ./meeting-notes.txt --plain
      cat notes.txt | localassist --fallback

    OPTIONS:
      --text <value>             Text to summarize.
      --file <path>              File to summarize.
      --max-suggestions <count>  Number of task suggestions, 1 through 8. Default: 5.
      --fallback                 Force deterministic offline fallback.
      --plain                    Print a human-readable summary instead of JSON.
      --help                     Show this help text.
    """
}

private struct CommandArguments {
    var text: String?
    var filePath: String?
    var maxSuggestions = 5
    var forceFallback = false
    var plainText = false
    var helpRequested = false

    init<S: Sequence>(_ rawArguments: S) where S.Element == String {
        var iterator = rawArguments.makeIterator()

        while let argument = iterator.next() {
            switch argument {
            case "--text":
                text = iterator.next()
            case "--file":
                filePath = iterator.next()
            case "--max-suggestions":
                if let value = iterator.next(), let parsed = Int(value) {
                    maxSuggestions = parsed
                }
            case "--fallback":
                forceFallback = true
            case "--plain":
                plainText = true
            case "--help", "-h":
                helpRequested = true
            default:
                if text == nil {
                    text = argument
                }
            }
        }
    }

    func resolveInput() throws -> String {
        if let text {
            return text
        }

        if let filePath {
            return try String(contentsOfFile: filePath, encoding: .utf8)
        }

        let data = FileHandle.standardInput.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self)
    }
}
