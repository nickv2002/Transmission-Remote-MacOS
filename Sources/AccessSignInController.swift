import AppKit

/// Runs Cloudflare Access sign-ins for the whole app, one at a time per server,
/// so Settings and the main window show the same "waiting for the browser"
/// state. A finished sign-in is stored in `AccessSessions`, whose notification
/// makes `RefreshController` reconnect with the new token.
@MainActor
final class AccessSignInController {
    static let shared = AccessSignInController()
    /// Posted when a server's phase changes; `userInfo[AccessSessions.serverIDKey]` is its id.
    static let phaseChangedNotification = Notification.Name("AccessSignInPhaseChanged")

    enum Phase: Equatable {
        case idle
        /// Waiting for the user to finish in the browser; the sign-in URL once known.
        case waiting(URL?)
        case failed(String)
    }

    var sessions: AccessSessions
    var environment: () -> AccessSignIn.Environment

    private var phases: [UUID: Phase] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]

    init(sessions: AccessSessions = .shared,
         environment: @escaping () -> AccessSignIn.Environment = AccessSignInController.defaultEnvironment) {
        self.sessions = sessions
        self.environment = environment
    }

    nonisolated static func defaultEnvironment() -> AccessSignIn.Environment {
        AccessSignIn.Environment(openBrowser: { url in
            await MainActor.run { NSWorkspace.shared.open(url) }
        })
    }

    func phase(for server: UUID) -> Phase { phases[server] ?? .idle }

    /// Starts signing in to the Access app in front of `server` (its id must be
    /// the configured server's). Ignored while one is already running for it.
    func signIn(server: ServerConfig) {
        let id = server.id
        guard tasks[id] == nil else { return }
        guard let appURL = Self.appURL(for: server) else {
            setPhase(.failed("Cloudflare Access sign-in needs an HTTPS host. Add one to Host, "
                + "for example https://transmission.example.com."), for: id)
            return
        }
        setPhase(.waiting(nil), for: id)
        let env = environment()
        let existing = sessions.session(for: id)
        let showURL: @Sendable (URL) -> Void = { [weak self] url in
            guard let self else { return }
            Task { @MainActor in
                if case .waiting = self.phase(for: id) { self.setPhase(.waiting(url), for: id) }
            }
        }
        tasks[id] = Task { [weak self] in
            do {
                let session = try await AccessSignIn.signIn(appURL: appURL, existing: existing, environment: env,
                                                            onSignInURL: showURL)
                guard let self else { return }
                try self.sessions.setSession(session, for: id)
                self.finish(id, .idle)
            } catch AccessError.cancelled {
                self?.finish(id, .idle)
            } catch {
                self?.finish(id, .failed(error.localizedDescription))
            }
        }
    }

    func cancel(server: UUID) {
        tasks[server]?.cancel()
    }

    /// Signs out: stops a sign-in in progress, revokes the tokens (best effort)
    /// and forgets them. The app's registration is kept for the next sign-in.
    func signOut(server: UUID) {
        cancel(server: server)
        if let session = sessions.session(for: server) {
            let env = environment()
            Task { await AccessSignIn.revoke(session, environment: env) }
            try? sessions.setSession(session.signedOut, for: server)
        }
        setPhase(.idle, for: server)
    }

    private func finish(_ id: UUID, _ phase: Phase) {
        tasks[id] = nil
        setPhase(phase, for: id)
    }

    private func setPhase(_ phase: Phase, for id: UUID) {
        guard phases[id] != phase else { return }
        phases[id] = phase
        NotificationCenter.default.post(name: Self.phaseChangedNotification, object: self,
                                        userInfo: [AccessSessions.serverIDKey: id])
    }

    // MARK: - Pure helpers (tested)

    /// The URL to sign in against: the server's RPC endpoint on its first HTTPS
    /// host candidate (Access only fronts HTTPS hosts).
    nonisolated static func appURL(for server: ServerConfig) -> URL? {
        guard let candidate = server.connectionCandidates.first(where: \.useHTTPS) else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = candidate.host
        if candidate.port != 443 { components.port = candidate.port }
        components.path = candidate.rpcPath.hasPrefix("/") ? candidate.rpcPath : "/" + candidate.rpcPath
        return components.url
    }

    /// One line describing a server's sign-in, for Settings.
    nonisolated static func statusText(session: AccessSession?, phase: Phase, now: Date,
                                       locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        switch phase {
        case .waiting: return "Waiting for you to sign in in your browser…"
        case .failed(let message): return message
        case .idle: break
        }
        guard let session, session.isSignedIn else { return "Not signed in." }
        let note = "Access renews the session automatically until it ends."
        guard let since = session.signedInAt else { return "Signed in. \(note)" }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return "Signed in · \(formatter.string(from: since)). \(note)"
    }
}
