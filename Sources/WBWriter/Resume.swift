import AppKit
import ImageIO
import UniformTypeIdentifiers

/// What a restart needs to come back exactly where it left off: live or not, the board, the message.
/// Saved right before a remote restart and consumed once on the next launch.
struct ResumeState: Codable {
    var live: Bool
    var message: String?
    var savedAt: Date

    private static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WBWriter/Resume", isDirectory: true)
    }
    private static var stateURL: URL { folder.appendingPathComponent("state.json") }
    private static var boardURL: URL { folder.appendingPathComponent("board.png") }

    static func save(_ state: ResumeState, board: CGImage?) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
        try? FileManager.default.removeItem(at: boardURL)
        if let board, let dest = CGImageDestinationCreateWithURL(boardURL as CFURL, UTType.png.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, board, nil)
            CGImageDestinationFinalize(dest)
        }
    }

    /// Returns the saved state (and board) if it's recent, and removes it so it's used only once.
    static func take(maxAge: TimeInterval = 300) -> (state: ResumeState, board: CGImage?)? {
        defer { try? FileManager.default.removeItem(at: folder) }
        guard let data = try? Data(contentsOf: stateURL),
              let state = try? JSONDecoder().decode(ResumeState.self, from: data),
              Date().timeIntervalSince(state.savedAt) < maxAge else { return nil }
        // Read the file into memory first: ImageIO decodes lazily, and the file is deleted on return.
        let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        let board = (try? Data(contentsOf: boardURL))
            .flatMap { CGImageSourceCreateWithData($0 as CFData, nil) }
            .flatMap { CGImageSourceCreateImageAtIndex($0, 0, options) }
        return (state, board)
    }
}

enum Relauncher {
    /// Quits and opens the app again once this process has exited, with extra launch arguments.
    static func relaunch(arguments: [String]) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let app = Bundle.main.bundleURL.path
        let script = """
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        /usr/bin/open "$1" --args "${@:2}"
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", script, "wbwriter-relaunch", app] + arguments
        try? p.run()
        NSApp.terminate(nil)
    }
}
