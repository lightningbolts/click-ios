import SwiftUI
import UIKit

/// System share sheet for a file that only exists after an async load (a decrypted attachment),
/// where a `ShareLink` can't be built up front.
struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
