import AppKit

/// The main window's side of Cloudflare Access: one prompt each time the active
/// server starts needing a sign-in, and Server ▸ Sign In to Cloudflare Access….
extension MainWindowController {
    /// Called by `RefreshController` when the need for a sign-in changes. It only
    /// reports changes, so the prompt appears once per episode, never per poll.
    /// The browser is never opened without a click.
    func accessSignInRequiredChanged(_ reason: AccessSignInReason?) {
        guard let reason, let window, window.attachedSheet == nil else { return }
        let server = refresh.activeServerConfig
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = reason == .expired ? "Cloudflare Access session ended" : "Cloudflare Access sign-in needed"
        alert.informativeText = ConnectionDiagnostics.accessMessage(reason, server: server)
        enum Choice { case signIn, settings, dismiss }
        let choices: [(String, Choice)]
        if reason == .managedOAuthOff {
            choices = [("OK", .dismiss)]
        } else if server.useCloudflareAccess {
            choices = [("Sign In…", .signIn), ("Not Now", .dismiss)]
        } else {
            choices = [("Open Server Settings", .settings), ("Not Now", .dismiss)]
        }
        for (title, _) in choices { alert.addButton(withTitle: title) }
        alert.beginSheetModal(for: window) { [weak self] response in
            let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            guard choices.indices.contains(index) else { return }
            switch choices[index].1 {
            case .signIn: self?.signInToCloudflareAccess(nil)
            case .settings: self?.onServerSettings?()
            case .dismiss: break
            }
        }
    }

    /// Whether Server ▸ Sign In to Cloudflare Access… applies to the active server.
    var canSignInToCloudflareAccess: Bool { refresh.activeServerConfig.useCloudflareAccess }

    @objc func signInToCloudflareAccess(_ sender: Any?) {
        guard canSignInToCloudflareAccess else { return }
        AccessSignInController.shared.signIn(server: refresh.activeServerConfig)
        showToast("Finish signing in in your browser. Transmission Remote reconnects when you’re done.")
    }
}
