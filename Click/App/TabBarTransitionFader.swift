import SwiftUI
import UIKit

/// Makes the system tab bar fade with navigation transitions the way WhatsApp's does.
///
/// Pushed screens hide the bar with `.toolbar(.hidden, for: .tabBar)` (layout), but SwiftUI only
/// flips its visibility when a transition starts or ends, so an interactive back-swipe would pop
/// the bar in at the end. This zero-size controller rides along each pushed screen and drives
/// the bar's alpha with `transitionCoordinator.animate(alongsideTransition:)`. UIKit scrubs
/// alongside animations with the finger, so the bar fades in exactly as far as the swipe has
/// gone, and a cancelled swipe fades it back out.
///
/// No swizzling and no `hidesBottomBarWhenPushed` (Docs/PLAN_ROUND6.md rule 4).
struct TabBarTransitionFader: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> FaderController { FaderController() }
    func updateUIViewController(_ controller: FaderController, context: Context) {}

    final class FaderController: UIViewController {
        override func loadView() {
            view = UIView(frame: .zero)
            view.isUserInteractionEnabled = false
        }

        private var navigation: UINavigationController? {
            var current: UIViewController? = parent
            while let controller = current {
                if let navigation = controller as? UINavigationController { return navigation }
                if let navigation = controller.navigationController { return navigation }
                current = controller.parent
            }
            return nil
        }

        private func isRoot(_ controller: UIViewController?, in navigation: UINavigationController) -> Bool {
            guard let controller, let root = navigation.viewControllers.first else { return false }
            return controller === root
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            guard let tabBar = tabBarController?.tabBar, let navigation else { return }
            guard let coordinator = transitionCoordinator ?? navigation.transitionCoordinator,
                  isRoot(coordinator.viewController(forKey: .from), in: navigation) else {
                // Arriving from another pushed screen (or without animation): stay hidden.
                return
            }
            // Leaving a tab root: fade the bar out with the push.
            tabBar.isHidden = false
            tabBar.alpha = 1
            coordinator.animate(alongsideTransition: { _ in
                tabBar.alpha = 0
            }, completion: { context in
                if context.isCancelled {
                    tabBar.alpha = 1
                } else {
                    tabBar.isHidden = true
                    tabBar.alpha = 1
                }
            })
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            guard let tabBar = tabBarController?.tabBar, let navigation else { return }
            guard let coordinator = transitionCoordinator ?? navigation.transitionCoordinator else {
                return
            }
            guard isRoot(coordinator.viewController(forKey: .to), in: navigation) else { return }
            // Returning to a tab root: fade the bar in, tracking an interactive swipe.
            tabBar.alpha = 0
            tabBar.isHidden = false
            coordinator.animate(alongsideTransition: { _ in
                tabBar.alpha = 1
            }, completion: { context in
                if context.isCancelled {
                    // Still on the pushed screen: hidden again, alpha reset for next time.
                    tabBar.isHidden = true
                }
                tabBar.alpha = 1
            })
        }
    }
}

/// Keeps the edge swipe-back working on a pushed screen that hides the navigation bar (UIKit's
/// default pop-gesture delegate refuses to begin when the bar is hidden). Scoped to this
/// screen: the original delegate is restored when it disappears.
struct SwipeBackEnabler: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) {}

    final class Controller: UIViewController, UIGestureRecognizerDelegate {
        private weak var previousDelegate: UIGestureRecognizerDelegate?
        private weak var navigation: UINavigationController?

        override func loadView() {
            view = UIView(frame: .zero)
            view.isUserInteractionEnabled = false
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard let navigation = parent?.navigationController ?? navigationController,
                  let recognizer = navigation.interactivePopGestureRecognizer else { return }
            self.navigation = navigation
            if recognizer.delegate !== self { previousDelegate = recognizer.delegate }
            recognizer.delegate = self
            recognizer.isEnabled = true
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            if let recognizer = navigation?.interactivePopGestureRecognizer, recognizer.delegate === self {
                recognizer.delegate = previousDelegate
            }
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            (navigation?.viewControllers.count ?? 0) > 1 && navigation?.transitionCoordinator == nil
        }
    }
}
