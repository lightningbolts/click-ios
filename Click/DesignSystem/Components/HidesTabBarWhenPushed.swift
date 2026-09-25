import SwiftUI
import UIKit

/// Marks the hosting screen `hidesBottomBarWhenPushed`, so popping back animates the tab bar in
/// with the navigation transition (and follows an interactive back swipe) instead of it
/// appearing only once the pop finishes.
struct HidesTabBarWhenPushed: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Marker { Marker() }
    func updateUIViewController(_ controller: Marker, context: Context) {}

    final class Marker: UIViewController {
        override func loadView() {
            view = UIView()
            view.isUserInteractionEnabled = false
        }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            mark()
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            mark()
        }

        /// The screen pushed onto the navigation stack is the ancestor whose parent is the
        /// `UINavigationController`.
        private func mark() {
            var current: UIViewController? = self
            while let controller = current, let parent = controller.parent {
                if parent is UINavigationController {
                    controller.hidesBottomBarWhenPushed = true
                    return
                }
                current = parent
            }
        }
    }
}

extension View {
    func hidesTabBarWhenPushed() -> some View {
        background(HidesTabBarWhenPushed().frame(width: 0, height: 0).accessibilityHidden(true))
    }
}
