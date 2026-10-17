import Foundation
import Network
import SystemConfiguration

/// Optional remote control over HTTP on the local network: clear the board and show a message
/// to the performer. Serves a small control page at `/` and a JSON API under `/api`.
final class WebControlServer {
    struct State {
        var live: Bool
        var message: String?
        var ndi: String?
    }

    var onClear: () -> Bool = { false }
    var onMessage: (_ text: String, _ seconds: Double?) -> Bool = { _, _ in false }
    var onClearMessage: () -> Bool = { false }
    var state: () -> State = { State(live: false, message: nil, ndi: nil) }
    /// Called on the main queue when the listener stops unexpectedly, e.g. the port is in use.
    var onFailure: (String) -> Void = { _ in }

    private let queue = DispatchQueue(label: "WBWriter.WebControl")
    private var listener: NWListener?
    private(set) var port: UInt16 = 0
    private var pin = ""

    /// Starts listening, or restarts with new settings. Returns an error message on failure.
    @discardableResult
    func start(port: UInt16, pin: String) -> String? {
        stop()
        self.pin = pin.trimmingCharacters(in: .whitespaces)
        guard let nwPort = NWEndpoint.Port(rawValue: port), port > 0 else { return "Port \(port) isn't valid." }
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters, on: nwPort)
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.stateUpdateHandler = { [weak self] state in
                guard case .failed(let error) = state else { return }
                DispatchQueue.main.async {
                    self?.onFailure("Web control stopped: port \(port) is unavailable (\(error.localizedDescription)).")
                }
            }
            listener.start(queue: queue)
            self.listener = listener
            self.port = port
            return nil
        } catch {
            return "Web control couldn't start on port \(port): \(error.localizedDescription)"
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        port = 0
    }

    /// Addresses the control page can be opened at, e.g. "http://Stage-Mac.local:8080".
    static func addresses(port: UInt16) -> [String] {
        var result: [String] = []
        if let host = SCDynamicStoreCopyLocalHostName(nil) as String? {
            result.append("http://\(host).local:\(port)")
        }
        var addrs: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&addrs) == 0, let first = addrs {
            defer { freeifaddrs(addrs) }
            var cursor: UnsafeMutablePointer<ifaddrs>? = first
            while let ifa = cursor {
                let entry = ifa.pointee
                if let addr = entry.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                   String(cString: entry.ifa_name).hasPrefix("en") {
                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count),
                                   nil, 0, NI_NUMERICHOST) == 0 {
                        result.append("http://\(String(cString: host)):\(port)")
                    }
                }
                cursor = entry.ifa_next
            }
        }
        return result
    }

    // MARK: Connections

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self else { return connection.cancel() }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = HTTPRequest(buffer) {
                self.handle(request, on: connection)
            } else if complete || error != nil || buffer.count > 256 * 1024 {
                connection.cancel()
            } else {
                self.receive(on: connection, buffer: buffer)
            }
        }
    }

    private func handle(_ request: HTTPRequest, on connection: NWConnection) {
        let authorized = pin.isEmpty || request.headers["x-wbwriter-pin"] == pin

        switch (request.method, request.path) {
        case ("GET", "/"), ("GET", "/index.html"):
            return send(connection, status: 200, type: "text/html; charset=utf-8", body: Data(WebControlPage.html.utf8))

        case ("GET", "/api/state"):
            var json: [String: Any] = ["pinRequired": !pin.isEmpty, "authorized": authorized]
            if authorized {
                let s = onMain { self.state() }
                json["live"] = s.live
                json["message"] = s.message ?? NSNull()
                json["ndi"] = s.ndi ?? NSNull()
            }
            return sendJSON(connection, status: 200, json)

        case ("POST", _):
            // A custom header can't be sent cross-site without a CORS preflight, which we never
            // allow, so other web pages in the operator's browser can't trigger these actions.
            guard request.headers["x-wbwriter"] != nil else {
                return sendJSON(connection, status: 403, ["error": "Missing X-WBWriter header."])
            }
            guard authorized else {
                return sendJSON(connection, status: 401, ["error": "Wrong PIN."])
            }
            let ok: Bool
            switch request.path {
            case "/api/clear":
                ok = onMain { self.onClear() }
            case "/api/message":
                let body = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any]
                let text = (body?["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !text.isEmpty else {
                    return sendJSON(connection, status: 400, ["error": "The message is empty."])
                }
                let seconds = (body?["seconds"] as? Double).flatMap { $0 > 0 ? $0 : nil }
                ok = onMain { self.onMessage(String(text.prefix(500)), seconds) }
            case "/api/message/clear":
                ok = onMain { self.onClearMessage() }
            default:
                return sendJSON(connection, status: 404, ["error": "Not found."])
            }
            if ok {
                sendJSON(connection, status: 200, ["ok": true])
            } else {
                sendJSON(connection, status: 409, ["error": "WBWriter isn't live. Go live on the stage Mac first."])
            }

        default:
            send(connection, status: 404, type: "text/plain; charset=utf-8", body: Data("Not found".utf8))
        }
    }

    private func onMain<T>(_ work: @escaping () -> T) -> T {
        if Thread.isMainThread { return work() }
        var result: T!
        DispatchQueue.main.sync { result = work() }
        return result
    }

    private func sendJSON(_ connection: NWConnection, status: Int, _ object: [String: Any]) {
        let body = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        send(connection, status: status, type: "application/json", body: body)
    }

    private func send(_ connection: NWConnection, status: Int, type: String, body: Data) {
        let reason = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden",
                      404: "Not Found", 409: "Conflict"][status] ?? "OK"
        let head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n"
            + "Cache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }
}

/// Minimal HTTP/1.1 request parser; returns nil until the headers and body are complete.
private struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    init?(_ data: Data) {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data[..<end.lowerBound], encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = end.upperBound
        guard data.count - bodyStart >= length else { return nil }
        method = String(parts[0])
        path = String(parts[1].split(separator: "?").first ?? "/")
        self.headers = headers
        body = data[bodyStart..<(bodyStart + length)]
    }
}

/// The control page, sized for a phone.
enum WebControlPage {
    static let html = """
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
    <meta name="theme-color" content="#0d0a12">
    <title>WBWriter Remote</title>
    <style>
    :root { --bg:#0d0a12; --surface:#17121e; --line:#2c2436; --fg:#f2eef8; --muted:#a59bb3; --brand:#4b1c7a; --accent:#b48cff; --warn:#ffd45a; --ok:#3ddc84; --bad:#ff6b6b; color-scheme: dark; }
    * { box-sizing: border-box; }
    [hidden] { display: none !important; }
    body { margin:0; background:var(--bg); color:var(--fg); font:16px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
           padding: max(16px, env(safe-area-inset-top)) max(16px, env(safe-area-inset-right)) max(24px, env(safe-area-inset-bottom)) max(16px, env(safe-area-inset-left)); }
    main { max-width: 520px; margin: 0 auto; display: grid; gap: 18px; }
    header { display:flex; align-items:center; justify-content:space-between; gap:12px; }
    h1 { font-size: 1.25rem; margin:0; }
    .pill { font-size:.8rem; padding:4px 12px; border-radius:999px; border:1px solid var(--line); color:var(--muted); white-space:nowrap; }
    .pill.live { color:var(--ok); border-color:var(--ok); }
    section { background:var(--surface); border:1px solid var(--line); border-radius:14px; padding:16px; display:grid; gap:12px; }
    h2 { font-size:.8rem; letter-spacing:.08em; text-transform:uppercase; color:var(--muted); margin:0; }
    button { font:inherit; font-weight:600; border-radius:12px; border:1px solid var(--line); background:#221a2b; color:var(--fg); padding:14px 16px; cursor:pointer; }
    button:disabled { opacity:.45; cursor:default; }
    button.primary { background:var(--brand); border-color:var(--brand); color:#fff; }
    button.danger { background:#3a1420; border-color:#6a2236; color:#ffd6dd; font-size:1.15rem; padding:20px; }
    button.danger.armed { background:#c62f4b; border-color:#c62f4b; color:#fff; }
    textarea, input, select { font:inherit; color:var(--fg); background:#0f0b14; border:1px solid var(--line); border-radius:10px; padding:12px; width:100%; }
    textarea { min-height: 90px; resize: vertical; }
    .row { display:flex; gap:10px; flex-wrap:wrap; }
    .row > * { flex:1 1 140px; }
    .current { color:var(--warn); font-weight:600; min-height:1.5em; overflow-wrap:anywhere; }
    .muted { color:var(--muted); font-size:.9rem; }
    #toast { position:fixed; left:50%; bottom:max(20px, env(safe-area-inset-bottom)); transform:translateX(-50%); background:#221a2b; border:1px solid var(--line); padding:10px 16px; border-radius:10px; opacity:0; transition:opacity .2s; pointer-events:none; }
    #toast.show { opacity:1; }
    :focus-visible { outline:2px solid var(--accent); outline-offset:2px; }
    </style>
    </head>
    <body>
    <main>
      <header><h1>WBWriter Remote</h1><span class="pill" id="live">Connecting…</span></header>

      <section id="pinBox" hidden>
        <h2>PIN</h2>
        <p class="muted">Enter the PIN shown in WBWriter's setup window.</p>
        <div class="row"><input id="pin" inputmode="numeric" autocomplete="off" placeholder="PIN"><button class="primary" id="pinSave">Unlock</button></div>
      </section>

      <section>
        <h2>Board</h2>
        <button class="danger" id="clear">Clear board</button>
        <p class="muted" id="clearHint">Tap twice to clear the performer's board.</p>
      </section>

      <section>
        <h2>Message to the performer</h2>
        <p class="muted">Shown on the touchscreen only, never on the LED wall.</p>
        <textarea id="text" maxlength="500" placeholder="e.g. Two minutes left"></textarea>
        <div class="row">
          <select id="seconds" aria-label="How long to show the message">
            <option value="0">Until removed</option>
            <option value="10">For 10 seconds</option>
            <option value="30">For 30 seconds</option>
            <option value="60">For 1 minute</option>
          </select>
          <button class="primary" id="send">Send</button>
        </div>
        <p class="muted">On screen now:</p>
        <p class="current" id="current">No message</p>
        <button id="remove">Remove message</button>
      </section>
    </main>
    <div id="toast" role="status"></div>
    <script>
    (() => {
      const $ = (id) => document.getElementById(id);
      let pin = ""; try { pin = localStorage.getItem("wbwriter-pin") || ""; } catch (e) {}
      const toast = (msg) => { const t = $("toast"); t.textContent = msg; t.classList.add("show"); clearTimeout(toast.h); toast.h = setTimeout(() => t.classList.remove("show"), 2200); };
      const headers = () => ({ "X-WBWriter": "1", "X-WBWriter-PIN": pin, "Content-Type": "application/json" });
      async function post(path, body) {
        try {
          const r = await fetch(path, { method: "POST", headers: headers(), body: JSON.stringify(body || {}) });
          const j = await r.json().catch(() => ({}));
          if (!r.ok) { toast(j.error || "Something went wrong."); if (r.status === 401) $("pinBox").hidden = false; return false; }
          return true;
        } catch (e) { toast("WBWriter can't be reached. Check the network."); return false; }
      }
      async function refresh() {
        try {
          const r = await fetch("/api/state", { headers: headers(), cache: "no-store" });
          const s = await r.json();
          $("pinBox").hidden = !(s.pinRequired && !s.authorized);
          const live = $("live");
          if (!s.authorized) { live.textContent = "Locked"; live.className = "pill"; return; }
          live.textContent = s.live ? "Live" : "Not live"; live.className = s.live ? "pill live" : "pill";
          $("current").textContent = s.message || "No message";
        } catch (e) { $("live").textContent = "Offline"; $("live").className = "pill"; }
      }
      let armed = null;
      $("clear").addEventListener("click", async () => {
        const b = $("clear");
        if (!armed) {
          b.classList.add("armed"); b.textContent = "Tap again to clear";
          armed = setTimeout(() => { armed = null; b.classList.remove("armed"); b.textContent = "Clear board"; }, 2500);
          return;
        }
        clearTimeout(armed); armed = null; b.classList.remove("armed"); b.textContent = "Clear board";
        if (await post("/api/clear")) toast("Board cleared");
      });
      $("send").addEventListener("click", async () => {
        const text = $("text").value.trim();
        if (!text) { toast("Type a message first."); return; }
        if (await post("/api/message", { text, seconds: Number($("seconds").value) })) { toast("Message shown"); refresh(); }
      });
      $("remove").addEventListener("click", async () => { if (await post("/api/message/clear")) { toast("Message removed"); refresh(); } });
      $("pinSave").addEventListener("click", () => { pin = $("pin").value.trim(); try { localStorage.setItem("wbwriter-pin", pin); } catch (e) {} refresh(); });
      refresh(); setInterval(refresh, 2000);
    })();
    </script>
    </body>
    </html>
    """
}
