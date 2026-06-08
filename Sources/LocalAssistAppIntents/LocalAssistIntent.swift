import AppIntents
import LocalAssistCore

@available(macOS 13.0, iOS 16.0, *)
public struct LocalAssistIntentPackage: AppIntentsPackage {
    public static var includedPackages: [any AppIntentsPackage.Type] = []
}
