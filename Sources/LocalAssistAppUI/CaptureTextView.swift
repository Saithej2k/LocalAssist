#if os(iOS)
    import AVFoundation
    import SwiftUI
    import UIKit

    /// UITextView-backed capture editor.
    ///
    /// SwiftUI's `TextEditor` cannot trigger the system "Scan Text" camera
    /// (the AutoFill Live Text flow), which is the best scan experience on
    /// the platform: live camera, system UI, recognized text inserted at the
    /// insertion point with no custom scanner code. `UIResponder` can, via
    /// `captureTextFromCamera` — so the editor drops down to UIKit and keeps
    /// everything else (placeholder, styling, clear button) in SwiftUI.
    struct CaptureTextView: UIViewRepresentable {
        @Binding var text: String
        @Binding var isFocused: Bool
        /// Incremented by the Scan button; each bump opens the system camera.
        @Binding var scanRequestCount: Int

        /// The system scan flow needs a camera; hide the affordance in the
        /// simulator and on devices without one.
        static var supportsCameraScan: Bool {
            AVCaptureDevice.default(for: .video) != nil
        }

        func makeCoordinator() -> Coordinator {
            Coordinator(self)
        }

        func makeUIView(context: Context) -> UITextView {
            let view = UITextView()
            view.delegate = context.coordinator
            view.backgroundColor = .clear
            view.font = Self.roundedBodyFont()
            view.adjustsFontForContentSizeCategory = true
            view.textContainerInset = UIEdgeInsets(top: 20, left: 12, bottom: 20, right: 12)
            view.keyboardDismissMode = .interactive
            view.inputAccessoryView = context.coordinator.makeAccessoryToolbar()
            return view
        }

        func updateUIView(_ view: UITextView, context: Context) {
            context.coordinator.parent = self

            if view.text != text {
                view.text = text
            }

            if context.coordinator.handledScanRequests != scanRequestCount {
                context.coordinator.handledScanRequests = scanRequestCount
                DispatchQueue.main.async {
                    view.becomeFirstResponder()
                    view.captureTextFromCamera(nil)
                }
                return
            }

            if isFocused, !view.isFirstResponder {
                DispatchQueue.main.async {
                    view.becomeFirstResponder()
                }
            } else if !isFocused, view.isFirstResponder {
                DispatchQueue.main.async {
                    view.resignFirstResponder()
                }
            }
        }

        private static func roundedBodyFont() -> UIFont {
            let base = UIFont.preferredFont(forTextStyle: .body)
            guard let descriptor = base.fontDescriptor.withDesign(.rounded) else {
                return base
            }
            return UIFont(descriptor: descriptor, size: 0)
        }

        final class Coordinator: NSObject, UITextViewDelegate {
            var parent: CaptureTextView
            var handledScanRequests = 0
            private weak var toolbarOwner: UITextView?

            init(_ parent: CaptureTextView) {
                self.parent = parent
            }

            func textViewDidChange(_ textView: UITextView) {
                parent.text = textView.text
            }

            func textViewDidBeginEditing(_ textView: UITextView) {
                toolbarOwner = textView
                if !parent.isFocused {
                    parent.isFocused = true
                }
            }

            func textViewDidEndEditing(_ textView: UITextView) {
                if parent.isFocused {
                    parent.isFocused = false
                }
            }

            /// Keyboard "Done" bar — TextEditor-style views have no return
            /// key that dismisses, so the accessory carries the affordance.
            func makeAccessoryToolbar() -> UIToolbar {
                let toolbar = UIToolbar(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
                toolbar.items = [
                    UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil),
                    UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(dismissKeyboard)),
                ]
                toolbar.sizeToFit()
                return toolbar
            }

            @objc private func dismissKeyboard() {
                toolbarOwner?.resignFirstResponder()
                if parent.isFocused {
                    parent.isFocused = false
                }
            }
        }
    }
#endif
