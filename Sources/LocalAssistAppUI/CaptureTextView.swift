#if os(iOS)
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

        /// The system scan flow needs a camera. Every iPhone and iPad has
        /// one, so this is a compile-time constant: probing AVCaptureDevice
        /// — even once — logs CoreMedia (Fig) errors at launch, and the
        /// system Scan Text UI copes gracefully if a camera is ever absent.
        #if targetEnvironment(simulator)
            static let supportsCameraScan = false
        #else
            static let supportsCameraScan = true
        #endif

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
            /// Built on UIInputView with a plain button: UIToolbar +
            /// UIBarButtonItem in an inputAccessoryView throws spurious
            /// unsatisfiable-constraint warnings (`ButtonWrapper.width == 0`)
            /// on first keyboard presentation.
            func makeAccessoryToolbar() -> UIView {
                let accessory = UIInputView(
                    frame: CGRect(x: 0, y: 0, width: 0, height: 44),
                    inputViewStyle: .keyboard
                )

                let done = UIButton(type: .system)
                done.setTitle("Done", for: .normal)
                done.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
                done.addTarget(self, action: #selector(dismissKeyboard), for: .touchUpInside)
                done.translatesAutoresizingMaskIntoConstraints = false

                accessory.addSubview(done)
                NSLayoutConstraint.activate([
                    done.trailingAnchor.constraint(equalTo: accessory.trailingAnchor, constant: -16),
                    done.centerYAnchor.constraint(equalTo: accessory.centerYAnchor),
                ])
                return accessory
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
