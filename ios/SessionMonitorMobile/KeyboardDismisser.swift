import SwiftUI
import UIKit

/// Tapping anywhere outside a text input puts the keyboard away. A window-level recognizer that
/// does not cancel touches, so buttons and scrolling keep working; SwiftUI tap gestures on the
/// container never saw taps that landed in a ScrollView.
@MainActor final class KeyboardDismisser: NSObject, UIGestureRecognizerDelegate {
  static let shared = KeyboardDismisser()
  private var installed: Set<ObjectIdentifier> = []

  func install(in window: UIWindow) {
    guard installed.insert(ObjectIdentifier(window)).inserted else { return }
    let tap = UITapGestureRecognizer(target: self, action: #selector(dismiss))
    tap.cancelsTouchesInView = false
    tap.delegate = self
    window.addGestureRecognizer(tap)
  }

  @objc private func dismiss() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
  }

  nonisolated func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
    MainActor.assumeIsolated {
      // Taps inside the input itself (moving the cursor) keep the keyboard.
      var view = touch.view
      while let current = view {
        if current is UITextView || current is UITextField { return false }
        view = current.superview
      }
      return true
    }
  }

  nonisolated func gestureRecognizer(
    _ recognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
  ) -> Bool { true }
}

/// Finds the hosting window and installs the dismisser on it.
struct KeyboardDismissInstaller: UIViewRepresentable {
  func makeUIView(context: Context) -> UIView { Probe() }
  func updateUIView(_ view: UIView, context: Context) {}

  final class Probe: UIView {
    override func didMoveToWindow() {
      super.didMoveToWindow()
      if let window { KeyboardDismisser.shared.install(in: window) }
    }
  }
}
