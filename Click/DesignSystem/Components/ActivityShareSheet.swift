import SwiftUI
import UIKit

/// System share sheet for what a `ShareLink` can't express: a file that only exists after an
/// async load (a decrypted attachment), or items that change with the destination
/// (`UIActivityItemSource`, like the Click Flyer's caption).
struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
