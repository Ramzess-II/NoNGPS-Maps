import UniformTypeIdentifiers

@objcMembers
final class MailComposer: NSObject {
  private static let mailComposer = MailComposer()
  private static var topViewController: UIViewController { .topViewController() }
  private static var onSent: (() -> Void)?

  override private init() {}

  /// Composes an email with the provided subject, body and attachment file for the given recipients.
  static func sendEmail(subject: String? = nil, body: String? = nil, toRecipients recipients: [String], attachmentFileURL: URL? = nil) {
    sendEmailWith(subject: subject ?? "",
                  body: body ?? "",
                  toRecipients: recipients,
                  attachmentFileURL: attachmentFileURL)
  }

  /// Composes an email with the files attached. Without Apple Mail set up, the share sheet gives the files to another
  /// app and the address is in the text: mailto can't carry attachments.
  /// - Parameter onSent: called after the mail is sent or the files are shared.
  @nonobjc static func sendEmail(subject: String, body: String, toRecipients recipients: [String], attachments: [URL],
                                 onSent: @escaping () -> Void) {
    guard MWMMailViewController.canSendMail() else {
      let text = "\(recipients.joined(separator: ", "))\n\(subject)\n\n\(body)"
      let share = UIActivityViewController(activityItems: [text] + attachments, applicationActivities: nil)
      share.completionWithItemsHandler = { _, completed, _, _ in
        if completed {
          onSent()
        }
      }
      let top = topViewController
      share.popoverPresentationController?.sourceView = top.view
      share.popoverPresentationController?.sourceRect = CGRect(origin: top.view.center, size: .zero)
      top.present(share, animated: true)
      return
    }
    let mailViewController = MWMMailViewController()
    mailViewController.mailComposeDelegate = mailComposer
    mailViewController.setSubject(subject)
    mailViewController.setMessageBody(body, isHTML: false)
    mailViewController.setToRecipients(recipients)
    for url in attachments {
      guard let data = try? Data(contentsOf: url) else { continue }
      let mimeType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
      mailViewController.addAttachmentData(data, mimeType: mimeType, fileName: url.lastPathComponent)
    }
    self.onSent = onSent
    topViewController.present(mailViewController, animated: true, completion: nil)
  }

  /// Composes an email with the additional app information and the log file attachment for the developers.
  static func sendBugReportWith(title: String) {
    func subject() -> String {
      let appInfo = AppInfo.shared()
      return String(format: "[%@-%@ iOS] %@", appInfo.bundleVersion, appInfo.buildNumber, title)
    }

    func body() -> String {
      let appInfo = AppInfo.shared()
      return String(format: "\n\n\n\n- %@ (%@)\n- NonGPS Maps %@-%@\n- %@-%@\n- %@\n",
                    appInfo.deviceModel, UIDevice.current.systemVersion,
                    appInfo.bundleVersion, appInfo.buildNumber,
                    Locale.current.languageCode ?? "",
                    Locale.current.regionCode ?? "",
                    Locale.preferredLanguages.joined(separator: ", "))
    }
    UIApplication.shared.showLoadingOverlay {
      let logFileURL = Logger.getLogFileURL()
      UIApplication.shared.hideLoadingOverlay {
        sendEmailWith(subject: subject(),
                      body: body(),
                      toRecipients: [SocialMedia.organicMapsEmail.link],
                      attachmentFileURL: logFileURL)
      }
    }
  }

  private static func sendEmailWith(subject: String, body: String, toRecipients recipients: [String], attachmentFileURL: URL? = nil) {
    // If the attachment file path is provided, the default mail composer should be used.
    if let attachmentFileURL {
      if MWMMailViewController.canSendMail(), let attachmentData = try? Data(contentsOf: attachmentFileURL) {
        let mailViewController = MWMMailViewController()
        mailViewController.mailComposeDelegate = mailComposer
        mailViewController.setSubject(subject)
        mailViewController.setMessageBody(body, isHTML: false)
        mailViewController.setToRecipients(recipients)
        mailViewController.addAttachmentData(attachmentData, mimeType: "application/zip", fileName: attachmentFileURL.lastPathComponent)
        topViewController.present(mailViewController, animated: true, completion: nil)
      } else {
        showMailComposingAlert(recipients: recipients)
      }
      return
    }

    // From iOS 14, it is possible to change the default mail app, and mailto should open a default mail app.
    if !openDefaultMailApp(subject: subject, body: body, recipients: recipients) {
      showMailComposingAlert(recipients: recipients)
    }
  }

  private static func openDefaultMailApp(subject: String, body: String, recipients: [String]) -> Bool {
    var components = URLComponents(string: "mailto:\(recipients.joined(separator: ";"))")
    components?.queryItems = [
      URLQueryItem(name: "subject", value: subject),
      URLQueryItem(name: "body", value: body.replacingOccurrences(of: "\n", with: "\r\n")),
    ]

    if let url = components?.url, UIApplication.shared.canOpenURL(url) {
      UIApplication.shared.open(url)
      return true
    }
    return false
  }

  private static func showMailComposingAlert(recipients: [String]) {
    let text = String(format: L("email_error_body"), recipients.joined(separator: ";"))
    let alert = UIAlertController(title: L("email_error_title"), message: text, preferredStyle: .alert)
    let action = UIAlertAction(title: L("ok"), style: .default, handler: nil)
    alert.addAction(action)
    topViewController.present(alert, animated: true, completion: nil)
  }
}

// MARK: - MFMailComposeViewControllerDelegate

extension MailComposer: MFMailComposeViewControllerDelegate {
  func mailComposeController(_ controller: MFMailComposeViewController, didFinishWith result: MFMailComposeResult,
                             error _: Error?) {
    controller.dismiss(animated: true, completion: nil)
    if result == .sent {
      Self.onSent?()
    }
    Self.onSent = nil
  }
}
