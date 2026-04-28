import QuickLook
import SafariServices
import SwiftUI

/// Wraps `QLPreviewController` so the Execution screen can present the original imported
/// pattern (image / PDF) inside a SwiftUI sheet. The preview takes a single file URL
/// because the Execution UI only ever previews one source at a time.
struct SourceFilePreview: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: QLPreviewController, context: Context) {
        context.coordinator.url = url
        uiViewController.reloadData()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL

        init(url: URL) {
            self.url = url
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as QLPreviewItem
        }
    }
}

/// SwiftUI wrapper that puts the QuickLook controller into a navigation stack with a
/// Done button — `QLPreviewController` doesn't expose a built-in dismiss when presented
/// via `UIViewControllerRepresentable`.
struct SourceFilePreviewSheet: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SourceFilePreview(url: url)
                .ignoresSafeArea()
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                    }
                }
        }
    }
}

/// Presents a remote web URL inside an in-app `SFSafariViewController`. Used for the
/// "Open Original Pattern" entry point so users stay inside the app instead of being
/// bounced out to Safari.
struct WebPagePreviewSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}
