import UIKit
import UniformTypeIdentifiers

/// Hands a link or a text that another app shares, e.g. a place in Google Maps, to the app as om://share?text=…
/// The app finds the place in it, see DeepLinkHandler.
final class ShareViewController: UIViewController {
  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    Task { @MainActor in
      let text = await sharedText()
      guard !text.isEmpty,
            let encoded = text.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
            let url = URL(string: "om://share?text=\(encoded)")
      else {
        complete()
        return
      }
      openApp(url)
    }
  }

  private func sharedText() async -> String {
    var parts: [String] = []
    func add(_ part: String?) {
      guard let part = part?.trimmingCharacters(in: .whitespacesAndNewlines), !part.isEmpty,
            !parts.contains(where: { $0.contains(part) }) else { return }
      parts.append(part)
    }

    for item in extensionContext?.inputItems as? [NSExtensionItem] ?? [] {
      add(item.attributedContentText?.string)
      for provider in item.attachments ?? [] {
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
          await add((try? provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL)?.absoluteString)
        } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
          await add(try? provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String)
        }
      }
    }
    return parts.joined(separator: "\n")
  }

  /// No public API lets a share extension open its app. UIApplication is reached through the responder chain.
  private func openApp(_ url: URL) {
    var responder: UIResponder? = self
    while let current = responder {
      if let application = current as? UIApplication {
        application.open(url, options: [:]) { [weak self] _ in self?.complete() }
        return
      }
      responder = current.next
    }
    complete()
  }

  private func complete() {
    extensionContext?.completeRequest(returningItems: nil)
  }
}
