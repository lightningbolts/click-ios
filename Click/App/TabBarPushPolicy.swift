import UIKit
import SwiftUI

/// Screens marked with `.hidesTabBarWhenPushed()` must hide the tab bar the UIKit way, set on
/// the pushed controller *before* the push begins. That's the only way UIKit animates the bar
/// out and back in with the navigation transition, including an interactive back swipe.
@MainActor
public enum TabBarPushPolicy {
    private static var isInstalled = false

    public static func install() {
        guard !isInstalled else { return }
        isInstalled = true
        swap(#selector(UINavigationController.pushViewController(_:animated:)),
             #selector(UINavigationController.click_pushViewController(_:animated:)))
        swap(#selector(UINavigationController.setViewControllers(_:animated:)),
             #selector(UINavigationController.click_setViewControllers(_:animated:)))
    }

    private static func swap(_ original: Selector, _ replacement: Selector) {
        guard let a = class_getInstanceMethod(UINavigationController.self, original),
              let b = class_getInstanceMethod(UINavigationController.self, replacement) else { return }
        method_exchangeImplementations(a, b)
    }

    /// True when the controller hosts a view marked `.hidesTabBarWhenPushed()`.
    public static func wantsHiddenTabBar(_ controller: UIViewController) -> Bool {
        controller.loadViewIfNeeded()
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()   // builds the SwiftUI hierarchy so the marker exists
        return controller.view.containsTabBarHidingMarker
    }
}

extension UINavigationController {
    @objc func click_pushViewController(_ controller: UIViewController, animated: Bool) {
        if TabBarPushPolicy.wantsHiddenTabBar(controller) { controller.hidesBottomBarWhenPushed = true }
        click_pushViewController(controller, animated: animated)   // calls the original (swapped)
    }

    @objc func click_setViewControllers(_ controllers: [UIViewController], animated: Bool) {
        for controller in controllers where !viewControllers.contains(controller) {
            if TabBarPushPolicy.wantsHiddenTabBar(controller) { controller.hidesBottomBarWhenPushed = true }
        }
        click_setViewControllers(controllers, animated: animated)
    }
}

public final class TabBarHidingMarkerView: UIView {}

public struct TabBarHidingMarker: UIViewRepresentable {
    public init() {}

    public func makeUIView(context: Context) -> TabBarHidingMarkerView {
        let view = TabBarHidingMarkerView(frame: .zero)
        view.isUserInteractionEnabled = false
        return view
    }

    public func updateUIView(_ uiView: TabBarHidingMarkerView, context: Context) {}
}

extension UIView {
    public var containsTabBarHidingMarker: Bool {
        if self is TabBarHidingMarkerView { return true }
        for subview in subviews {
            if subview.containsTabBarHidingMarker { return true }
        }
        return false
    }
}

extension View {
    public func hidesTabBarWhenPushed() -> some View {
        background(TabBarHidingMarker().frame(width: 0, height: 0).accessibilityHidden(true))
    }
}
