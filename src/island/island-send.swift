import Foundation

// ─────────────────────────────────────────────────────────────────────────
// island-send — reads a normalized JSON payload on stdin, writes it atomically
// to ~/.claude-island/event.json, then posts a Darwin notification to wake the
// running ClaudeIsland daemon. Fire-and-forget, exits immediately.
//
//   echo '{"mode":"working","title":"Claude Code","detail":"Working…"}' | island-send
// ─────────────────────────────────────────────────────────────────────────

let dir = NSString("~/.claude-island").expandingTildeInPath
let darwinName = "com.claude-island.event"

// Optional output path (arg 1), relative to the island dir or absolute.
// Defaults to event.json for backward compatibility.
let outArg = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "event.json"
let file = outArg.hasPrefix("/") ? outArg : dir + "/" + outArg

let data = FileHandle.standardInput.readDataToEndOfFile()
guard !data.isEmpty else { exit(0) }

// Ensure the parent directory exists (e.g. ~/.claude-island/sessions).
try? FileManager.default.createDirectory(
    atPath: (file as NSString).deletingLastPathComponent, withIntermediateDirectories: true)

// Atomic write so the daemon never reads a half-written file.
do {
    try data.write(to: URL(fileURLWithPath: file), options: .atomic)
} catch {
    FileHandle.standardError.write("island-send: write failed: \(error)\n".data(using: .utf8)!)
    exit(1)
}

let center = CFNotificationCenterGetDarwinNotifyCenter()
CFNotificationCenterPostNotification(center,
                                     CFNotificationName(darwinName as CFString),
                                     nil, nil, true)
