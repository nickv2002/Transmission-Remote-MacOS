import Foundation
import ImageIO
import Network
import Synchronization

/// Receives the browser's redirect at the end of an OAuth sign-in.
protocol AuthorizationCallbackReceiver: Sendable {
    /// The local port the redirect URI points at.
    var port: UInt16 { get }
    /// Only a callback carrying this `state` (or an `error` with it) ends the wait;
    /// anything else that reaches the port, from another local process or a web
    /// page, is answered and ignored. Call before opening the browser.
    func expect(state: String)
    /// The query of the first `GET /callback?…` the browser sends.
    func waitForCallback() async throws -> [String: String]
    func close()
}

extension AuthorizationCallbackReceiver {
    func expect(state: String) {}
}

/// A one-shot HTTP listener on 127.0.0.1 for the OAuth redirect (RFC 8252 §7.3).
/// It answers `/callback` with a short result page (see `page(for:)`) and
/// anything else with 404, and never listens on another interface.
final class LoopbackCallbackServer: AuthorizationCallbackReceiver {
    private struct State {
        var result: Result<[String: String], Error>?
        var waiter: CheckedContinuation<[String: String], Error>?
        var expectedState: String?
    }

    let port: UInt16
    private let listener: NWListener
    private let queue: DispatchQueue
    private let state = Mutex(State())

    private init(listener: NWListener, port: UInt16, queue: DispatchQueue) {
        self.listener = listener
        self.port = port
        self.queue = queue
    }

    /// Starts listening on `preferredPort`, or any free port when nil. Throws if
    /// that port is taken.
    static func start(preferredPort: UInt16? = nil) async throws -> LoopbackCallbackServer {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1",
                                                     port: NWEndpoint.Port(rawValue: preferredPort ?? 0) ?? .any)
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "access.loopback")
        let started = Mutex(false)
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { newState in
                switch newState {
                case .ready:
                    if started.withLock({ let was = $0; $0 = true; return !was }) {
                        continuation.resume(returning: listener.port?.rawValue ?? 0)
                    }
                case .failed(let error):
                    if started.withLock({ let was = $0; $0 = true; return !was }) {
                        continuation.resume(throwing: AccessError.authorization(
                            "couldn’t listen for the browser on 127.0.0.1 (\(error.localizedDescription))"))
                    }
                default: break
                }
            }
            listener.newConnectionHandler = { _ in }   // replaced once the server exists
            listener.start(queue: queue)
        }
        let server = LoopbackCallbackServer(listener: listener, port: port, queue: queue)
        listener.newConnectionHandler = { [weak server] connection in server?.handle(connection) }
        listener.stateUpdateHandler = { [weak server] newState in
            if case .failed(let error) = newState {
                server?.finish(.failure(AccessError.authorization(error.localizedDescription)))
            }
        }
        return server
    }

    func expect(state: String) {
        self.state.withLock { $0.expectedState = state }
    }

    func waitForCallback() async throws -> [String: String] {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let ready: Result<[String: String], Error>? = state.withLock { s in
                    if let result = s.result { return result }
                    s.waiter = continuation
                    return nil
                }
                if let ready { continuation.resume(with: ready) }
            }
        } onCancel: {
            finish(.failure(AccessError.cancelled))
        }
    }

    func close() {
        listener.cancel()
        finish(.failure(AccessError.cancelled))
    }

    private func finish(_ result: Result<[String: String], Error>) {
        let waiter: CheckedContinuation<[String: String], Error>? = state.withLock { s in
            guard s.result == nil else { return nil }
            s.result = result
            defer { s.waiter = nil }
            return s.waiter
        }
        waiter?.resume(with: result)
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        // A client that connects and says nothing mustn't hold the connection open.
        queue.asyncAfter(deadline: .now() + 10) { connection.cancel() }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self else { connection.cancel(); return }
            let request = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
            var query = Self.callbackQuery(fromRequest: request)
            // Only the browser that was sent to sign in carries our state.
            if let q = query, q["state"] != self.state.withLock({ $0.expectedState }) { query = nil }
            let status = query == nil ? "404 Not Found" : "200 OK"
            let html = Self.page(for: query)
            let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\n"
                + "Content-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            if let query { self.finish(.success(query)) }
        }
    }

    /// The page the browser shows for a request: nil (not the callback) gets
    /// "Not found."; the callback gets the result in a card laid out like
    /// Cloudflare Access's own pages, under the app's icon and name. Nothing
    /// from the query is echoed into the page. `icon` is a PNG shown inline.
    static func page(for query: [String: String]?, icon: Data? = appIcon) -> String {
        let (title, message) = switch query {
        case nil: ("Not found", "This address only answers Transmission Remote’s sign-in.")
        case let q? where q["error"] != nil:
            ("Sign-in didn’t complete", "Return to Transmission Remote to see why and try again.")
        default: ("Signed in", "You’re signed in to Cloudflare Access. You can close this tab and "
                  + "return to Transmission Remote.")
        }
        let image = icon.map { "<img src=\"data:image/png;base64,\($0.base64EncodedString())\" alt=\"\">" } ?? ""
        return """
            <!doctype html><html lang=en><meta charset=utf-8>
            <meta name=viewport content="width=device-width,initial-scale=1">
            <meta name=color-scheme content="light dark"><title>\(title) · Transmission Remote</title>
            <style>
            :root{--canvas:#fafafa;--base:#fff;--hairline:#e8e8e8;--text:#18181b;--subtle:#71717a}
            @media (prefers-color-scheme:dark){:root{--canvas:#000;--base:#111;--hairline:#262626;\
            --text:#fafafa;--subtle:#a1a1aa}}
            body{margin:0;min-height:100vh;display:flex;flex-direction:column;align-items:center;\
            padding:32px 8px;box-sizing:border-box;background:var(--canvas);color:var(--text);\
            font:14px/20px -apple-system,BlinkMacSystemFont,"Segoe UI",Helvetica,Arial,sans-serif;\
            -webkit-font-smoothing:antialiased}
            main{width:100%;max-width:460px;display:flex;flex-direction:column;gap:20px}
            header{display:flex;flex-direction:column;align-items:center;gap:8px;font-size:20px;\
            line-height:28px;font-weight:600}
            header img{width:64px;height:64px}
            .card{background:var(--base);border:1px solid var(--hairline);border-radius:8px;padding:20px;\
            display:flex;flex-direction:column;gap:16px}
            h1{margin:0;font-size:20px;line-height:32px;font-weight:600}
            p{margin:0;color:var(--text)}
            </style>
            <main><header>\(image)<span>Transmission Remote</span></header>
            <div class=card><h1>\(title)</h1><p>\(message)</p></div></main>
            """
    }

    /// The app's icon as a 128-pixel PNG, or nil outside the app bundle.
    static let appIcon: Data? = {
        guard let url = Bundle.main.url(forResource: "DockIcon", withExtension: "png"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 128,
              ] as CFDictionary) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }()

    /// The query parameters of a `GET /callback?…` request line, or nil for any
    /// other request.
    static func callbackQuery(fromRequest request: String) -> [String: String]? {
        guard let line = request.split(separator: "\r\n", maxSplits: 1).first ?? request.split(separator: "\n").first
        else { return nil }
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET",
              let components = URLComponents(string: "http://127.0.0.1" + parts[1]),
              components.path == "/callback" else { return nil }
        var result: [String: String] = [:]
        for item in components.queryItems ?? [] { result[item.name] = item.value ?? "" }
        return result
    }
}
