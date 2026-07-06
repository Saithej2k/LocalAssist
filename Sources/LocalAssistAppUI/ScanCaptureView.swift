import SwiftUI
#if os(iOS) && canImport(VisionKit)
    import VisionKit
#endif

/// Camera scan capture: point at a whiteboard, receipt, or handwritten note
/// and Live Text extracts it on device — the Visual-Intelligence-style entry
/// into the same brief pipeline. Falls back to guidance where the scanner
/// isn't available (simulator, no camera).
public struct ScanCaptureSheet: View {
    public var onUseText: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var collectedLines: [String] = []

    public init(onUseText: @escaping (String) -> Void) {
        self.onUseText = onUseText
    }

    public var body: some View {
        NavigationStack {
            content
                .navigationTitle("Scan to capture")
                #if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
                #endif
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") {
                                dismiss()
                            }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Use Text") {
                                onUseText(collectedLines.joined(separator: "\n"))
                                dismiss()
                            }
                            .disabled(collectedLines.isEmpty)
                        }
                    }
        }
    }

    @ViewBuilder
    private var content: some View {
        #if os(iOS) && canImport(VisionKit)
            if DataScannerViewController.isSupported, DataScannerViewController.isAvailable {
                VStack(spacing: 0) {
                    LiveTextScannerView(collectedLines: $collectedLines)

                    VStack(alignment: .leading, spacing: 6) {
                        Text(collectedLines.isEmpty
                            ? "Point the camera at text. Recognized lines appear here."
                            : collectedLines.suffix(4).joined(separator: "\n"))
                            .font(.system(.caption, design: .rounded))
                            .foregroundStyle(collectedLines.isEmpty ? .secondary : .primary)
                            .lineLimit(4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if !collectedLines.isEmpty {
                            Text("\(collectedLines.count) lines captured — everything stays on device.")
                                .font(.system(.caption2, design: .rounded, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(14)
                }
            } else {
                unavailableView
            }
        #else
            unavailableView
        #endif
    }

    private var unavailableView: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.viewfinder")
                .font(.system(size: 42, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("Scanning needs a device camera")
                .font(.system(.headline, design: .rounded))
            Text("Run LocalAssist on an iPhone to capture whiteboards, receipts, and handwriting. You can still paste or dictate here.")
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#if os(iOS) && canImport(VisionKit)
    private struct LiveTextScannerView: UIViewControllerRepresentable {
        @Binding var collectedLines: [String]

        func makeUIViewController(context: Context) -> DataScannerViewController {
            let scanner = DataScannerViewController(
                recognizedDataTypes: [.text()],
                qualityLevel: .balanced,
                recognizesMultipleItems: true,
                isHighFrameRateTrackingEnabled: false,
                isHighlightingEnabled: true
            )
            scanner.delegate = context.coordinator
            try? scanner.startScanning()
            return scanner
        }

        func updateUIViewController(_: DataScannerViewController, context _: Context) {}

        func makeCoordinator() -> Coordinator {
            Coordinator(collectedLines: $collectedLines)
        }

        final class Coordinator: NSObject, DataScannerViewControllerDelegate {
            @Binding var collectedLines: [String]

            init(collectedLines: Binding<[String]>) {
                _collectedLines = collectedLines
            }

            func dataScanner(
                _: DataScannerViewController,
                didAdd addedItems: [RecognizedItem],
                allItems _: [RecognizedItem]
            ) {
                for item in addedItems {
                    if case .text(let text) = item {
                        let line = text.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !line.isEmpty, !collectedLines.contains(line) else {
                            continue
                        }
                        collectedLines.append(line)
                    }
                }
            }
        }
    }
#endif
