import AppKit
import Security
import SwiftUI

/// A release as returned by the GitHub API.
struct ReleaseInfo: Decodable {
    struct Asset: Decodable {
        let name: String
        let browser_download_url: String
    }

    let tag_name: String
    let body: String?
    let html_url: String
    let assets: [Asset]

    var version: String { tag_name.hasPrefix("v") ? String(tag_name.dropFirst()) : tag_name }
    var zipAsset: Asset? { assets.first { $0.name.hasPrefix("WBWriter") && $0.name.hasSuffix(".zip") } }
}

enum AppVersion {
    static var current: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// Compares dotted version numbers, e.g. 1.10.0 > 1.9.2.
    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}

/// Checks GitHub for a newer release, shows its changelog and installs it in place.
/// Updates are only installed when they are signed by the 4H1M Developer ID team.
final class Updater: ObservableObject {
    enum Phase: Equatable {
        case ready
        case downloading(Double)
        case installing
        case failed(String)
    }

    static let latestURL = URL(string: "https://api.github.com/repos/4H1Mzs/wbwriter/releases/latest")!
    static let teamID = "5BNMD65YZJ"
    static let bundleID = "com.cechacek.wbwriter"

    @Published private(set) var release: ReleaseInfo?
    @Published private(set) var phase: Phase = .ready

    /// Returns false while the show is live; the offer waits until setup is visible again.
    var canPresent: () -> Bool = { true }
    private var pendingPresentation = false
    private var window: NSWindow?
    private var progressObservation: NSKeyValueObservation?

    // MARK: Checking

    func check(userInitiated: Bool) {
        var request = URLRequest(url: Self.latestURL, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("WBWriter/\(AppVersion.current)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { data, response, _ in
            let release = data.flatMap { (response as? HTTPURLResponse)?.statusCode == 200 ? $0 : nil }
                .flatMap { try? JSONDecoder().decode(ReleaseInfo.self, from: $0) }
            DispatchQueue.main.async { self.handle(release, userInitiated: userInitiated) }
        }.resume()
    }

    private func handle(_ release: ReleaseInfo?, userInitiated: Bool) {
        guard let release else {
            if userInitiated {
                alert("Couldn't check for updates",
                      "WBWriter couldn't reach GitHub. Check the internet connection and try again.")
            }
            return
        }
        let newer = AppVersion.isNewer(release.version, than: AppVersion.current)
        let skipped = UserDefaults.standard.string(forKey: "skippedVersion") == release.version
        if newer && (userInitiated || !skipped) {
            self.release = release
            phase = .ready
            present()
        } else if userInitiated {
            alert("You're up to date", "WBWriter \(AppVersion.current) is the latest version.")
        }
    }

    // MARK: Window

    func present() {
        guard release != nil else { return }
        guard canPresent() else { pendingPresentation = true; return }
        pendingPresentation = false
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: UpdateView(updater: self)))
            w.title = "Software Update"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        runTestHookIfRequested()
    }

    /// WBWRITER_UPDATE_TEST=/path/offer.png saves the offer window and installs without a click,
    /// so the whole update path can be tested on a Mac without a display.
    private func runTestHookIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["WBWRITER_UPDATE_TEST"], phase == .ready,
              let view = window?.contentView else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
            self.install()
        }
    }

    /// Call when the setup window is shown again after a live session.
    func presentIfPending() {
        if pendingPresentation { present() }
    }

    func later() {
        window?.close()
    }

    func skipThisVersion() {
        if let release { UserDefaults.standard.set(release.version, forKey: "skippedVersion") }
        window?.close()
    }

    // MARK: Installing

    func install() {
        guard let release, let asset = release.zipAsset, let url = URL(string: asset.browser_download_url) else {
            return fail("This release has no macOS download. Download it from GitHub instead.")
        }
        let target = Bundle.main.bundleURL
        let folder = target.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: folder.path) else {
            return fail("WBWriter can't replace itself in “\(folder.path)”. Download the update from GitHub instead.")
        }

        phase = .downloading(0)
        let task = URLSession.shared.downloadTask(with: url) { tmp, response, _ in
            guard let tmp, (response as? HTTPURLResponse)?.statusCode == 200 else {
                return DispatchQueue.main.async { self.fail("The download failed. Check the internet connection and try again.") }
            }
            // The temporary file is removed when this handler returns, so move it first.
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("WBWriter-update-\(UUID().uuidString)")
            let zip = work.appendingPathComponent(asset.name)
            do {
                try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: tmp, to: zip)
            } catch {
                return DispatchQueue.main.async { self.fail("The update couldn't be saved: \(error.localizedDescription)") }
            }
            DispatchQueue.global(qos: .userInitiated).async {
                self.prepare(zip: zip, in: work, version: release.version, target: target)
            }
        }
        progressObservation = task.progress.observe(\.fractionCompleted) { progress, _ in
            DispatchQueue.main.async {
                if case .downloading = self.phase { self.phase = .downloading(progress.fractionCompleted) }
            }
        }
        task.resume()
    }

    private func prepare(zip: URL, in work: URL, version: String, target: URL) {
        let extracted = work.appendingPathComponent("extracted")
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", zip.path, extracted.path]
        let app = extracted.appendingPathComponent("WBWriter.app")
        do {
            try unzip.run()
            unzip.waitUntilExit()
        } catch {}
        guard unzip.terminationStatus == 0, FileManager.default.fileExists(atPath: app.path) else {
            return DispatchQueue.main.async { self.fail("The downloaded update is damaged. Try again later.") }
        }
        guard Self.isTrusted(app: app, version: version) else {
            return DispatchQueue.main.async {
                self.fail("The downloaded update isn't signed by 4H1M, so it wasn't installed.")
            }
        }
        DispatchQueue.main.async {
            self.phase = .installing
            self.relaunch(into: app, replacing: target)
        }
    }

    /// The update must carry a valid Apple-issued signature from the 4H1M team,
    /// the WBWriter bundle identifier, and the version the release announced.
    static func isTrusted(app: URL, version: String) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { return false }
        let text = "anchor apple generic and identifier \"\(bundleID)\" and certificate leaf[subject.OU] = \"\(teamID)\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        guard SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess else { return false }
        return Bundle(url: app)?.infoDictionary?["CFBundleShortVersionString"] as? String == version
    }

    /// Hands over to a small shell script that swaps the bundle once this process has quit,
    /// restores the previous version if the copy fails, and opens the result.
    private func relaunch(into app: URL, replacing target: URL) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        backup="$2.previous"
        rm -rf "$backup"
        if mv "$2" "$backup"; then
          if /usr/bin/ditto "$1" "$2"; then rm -rf "$backup"; else rm -rf "$2"; mv "$backup" "$2"; fi
        fi
        /usr/bin/open "$2"
        """
        let swap = Process()
        swap.executableURL = URL(fileURLWithPath: "/bin/sh")
        swap.arguments = ["-c", script, "wbwriter-update", app.path, target.path]
        do {
            try swap.run()
        } catch {
            return fail("The update couldn't be installed: \(error.localizedDescription)")
        }
        NSApp.terminate(nil)
    }

    private func fail(_ message: String) {
        phase = .failed(message)
        present()
    }

    private func alert(_ title: String, _ message: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.runModal()
    }
}

// MARK: - Views

struct UpdateView: View {
    @ObservedObject var updater: Updater

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text("WBWriter \(updater.release?.version ?? "") is available")
                        .font(.title2.weight(.bold))
                    Text("You have version \(AppVersion.current). Here's what's new:")
                        .foregroundStyle(.secondary)
                }
            }

            ScrollView {
                ReleaseNotesView(markdown: updater.release?.body ?? "")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
            .frame(minHeight: 160, maxHeight: 300)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor)))

            status

            HStack {
                Button("Skip This Version") { updater.skipThisVersion() }
                    .disabled(busy)
                Spacer()
                Button("Later") { updater.later() }
                    .disabled(busy)
                Button("Install and Restart") { updater.install() }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(red: 0.36, green: 0.13, blue: 0.6))
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy)
            }
        }
        .padding(22)
        .frame(width: 540)
    }

    private var busy: Bool {
        switch updater.phase {
        case .downloading, .installing: return true
        default: return false
        }
    }

    @ViewBuilder private var status: some View {
        switch updater.phase {
        case .ready:
            EmptyView()
        case .downloading(let fraction):
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: fraction)
                Text("Downloading… \(Int(fraction * 100)) %").font(.caption).foregroundStyle(.secondary)
            }
        case .installing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Installing. WBWriter will restart.").font(.callout)
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 4) {
                Text(message).foregroundStyle(.red).font(.callout)
                if let link = updater.release.flatMap({ URL(string: $0.html_url) }) {
                    Link("Open the release on GitHub", destination: link).font(.callout)
                }
            }
        }
    }
}

/// Renders the GitHub release notes: headings, bullets and paragraphs with inline Markdown.
/// HTML tags are dropped, and the notes stop at the “Download” section.
struct ReleaseNotesView: View {
    private enum Block {
        case heading(String), bullet(String), paragraph(String)
    }

    private let blocks: [Block]

    init(markdown: String) {
        var blocks: [Block] = []
        let plain = markdown.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for raw in plain.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line == "---" { continue }
            if line.hasPrefix("#") {
                let title = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                if title.lowercased() == "download" { break }
                blocks.append(.heading(title))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                blocks.append(.bullet(String(line.dropFirst(2))))
            } else {
                blocks.append(.paragraph(line))
            }
        }
        self.blocks = blocks
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let text):
                    Text(inline(text)).font(.headline)
                case .bullet(let text):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•")
                        Text(inline(text))
                    }
                case .paragraph(let text):
                    Text(inline(text))
                }
            }
        }
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}
