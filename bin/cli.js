#!/usr/bin/env node

const { execFileSync, spawn } = require("child_process");
const fs = require("fs");
const os = require("os");
const path = require("path");
const readline = require("readline");

const HOME = process.env.HOME;
const APP_DIR = path.join(HOME, "Applications");
const APP_PATH = path.join(APP_DIR, "AgentsIsland.app");
const MACOS_DIR = path.join(APP_PATH, "Contents", "MacOS");
const ISLAND_SRC = path.join(__dirname, "..", "src", "island", "island.swift");
const SEND_SRC = path.join(__dirname, "..", "src", "island", "island-send.swift");
const HOOK_SRC = path.join(__dirname, "..", "src", "island", "island-hook.py");
const STATUSLINE_SRC = path.join(__dirname, "..", "src", "island", "island-statusline.py");
const ASSETS_DIR = path.join(__dirname, "..", "src", "island", "assets");
const SETTINGS_PATH = path.join(HOME, ".claude", "settings.json");
const LAUNCH_AGENTS = path.join(HOME, "Library", "LaunchAgents");
const PLIST_LABEL = "com.agents-island.app";
const PLIST_PATH = path.join(LAUNCH_AGENTS, `${PLIST_LABEL}.plist`);
const EVENT_DIR = path.join(HOME, ".agents-island");
const VERSION = require("../package.json").version;
const LOCAL_CODESIGN_NAME = "Agents Island Local";

// Pre-rename identity (was "Claude Island"). An upgrader has the old app, LaunchAgent, and state
// dir on disk; install() clears them first so the old daemon can't linger beside the new one.
const LEGACY = {
  label: "com.claude-island.app",
  plist: path.join(LAUNCH_AGENTS, "com.claude-island.app.plist"),
  app: path.join(APP_DIR, "ClaudeIsland.app"),
  eventDir: path.join(HOME, ".claude-island"),
};

// Matches hooks owned by this tool or the ancestors we migrate from. Every alternative must be
// a name WE own: anything matching gets stripped from the user's settings on install and deleted
// on uninstall. `island-hook` catches our hook command under any app dir (the script name never
// changed), so it covers both the old ClaudeIsland and new AgentsIsland installs; `claude-island`
// stays listed so a pre-rename install migrates cleanly. (A bare `stop-hook` was once here — it
// would eat an unrelated `~/bin/stop-hook.sh`, and matched nothing `ClaudeNotify` didn't already:
// the legacy command was always `~/Applications/ClaudeNotify.app/Contents/MacOS/stop-hook.sh`.)
const MINE = /agents-island|claude-island|island-hook|ClaudeNotify|ClaudeCodeNotification/;

// The hook events we own → the event name each passes to island-hook.py. Install writes
// exactly these; uninstall removes exactly these. One list, so the two can never drift.
const HOOK_EVENTS = {
  UserPromptSubmit: "prompt",
  PreToolUse: "tool",
  PostToolUse: "post",
  Notification: "attention",
  Stop: "stop",
  PreCompact: "compact",         // → "Compacting…"
  SessionStart: "sessionstart",  // source=compact → "Compacted"
};

// ── Colors ──────────────────────────────────────────────────────────────

const c = {
  reset: "\x1b[0m",
  bold: "\x1b[1m",
  dim: "\x1b[2m",
  orange: "\x1b[38;5;208m",
  peach: "\x1b[38;5;216m",
  green: "\x1b[38;5;114m",
  red: "\x1b[38;5;203m",
  gray: "\x1b[38;5;243m",
  white: "\x1b[38;5;255m",
  cyan: "\x1b[38;5;117m",
  up: "\x1b[1A",
  clearLine: "\x1b[2K",
};

const W = 52;

function center(text, width) {
  const vis = text.replace(/\x1b\[[0-9;]*m/g, "");
  const left = Math.max(0, Math.floor((width - vis.length) / 2));
  const right = Math.max(0, width - vis.length - left);
  return " ".repeat(left) + text + " ".repeat(right);
}

const titleBar = `─── ${c.reset}${c.bold}${c.white}agents-island${c.reset} ${c.dim}v${VERSION} `;
const titleVis = `─── agents-island v${VERSION} `;
const titlePad = "─".repeat(Math.max(0, W - titleVis.length));

const LOGO = `
${c.dim}╭${titleBar}${titlePad}╮${c.reset}
${c.dim}│${" ".repeat(W)}│${c.reset}
${c.dim}│${c.reset}${center(`${c.white}╭─────────╮${c.reset}`, W)}${c.dim}│${c.reset}
${c.dim}│${c.reset}${center(`${c.white}│ ${c.peach}◜◞${c.white}  ···· │${c.reset}`, W)}${c.dim}│${c.reset}
${c.dim}│${c.reset}${center(`${c.white}╰─────────╯${c.reset}`, W)}${c.dim}│${c.reset}
${c.dim}│${" ".repeat(W)}│${c.reset}
${c.dim}│${c.reset}${center(`${c.gray}A live activity in your notch for your coding agents${c.reset}`, W)}${c.dim}│${c.reset}
${c.dim}│${c.reset}${center(`${c.dim}by Keshav Narula · x.com/narulakeshav${c.reset}`, W)}${c.dim}│${c.reset}
${c.dim}╰${"─".repeat(W)}╯${c.reset}
`;

function log(msg = "") { console.log(`  ${msg}`); }
function done(msg) { console.log(`  ${c.green}✓${c.reset} ${msg}`); }
function warn(msg) { console.log(`  ${c.red}✗${c.reset} ${msg}`); }
function info(msg) { console.log(`  ${c.gray}${msg}${c.reset}`); }
function hr() { console.log(`  ${c.dim}${"─".repeat(44)}${c.reset}`); }

function sleep(ms) { return new Promise((r) => setTimeout(r, ms)); }

function spinner(msg) {
  const frames = ["◐", "◓", "◑", "◒"];
  let i = 0;
  process.stdout.write(`  ${c.orange}${frames[0]}${c.reset} ${msg}`);
  const id = setInterval(() => {
    i = (i + 1) % frames.length;
    process.stdout.write(`${c.up}${c.clearLine}\r  ${c.orange}${frames[i]}${c.reset} ${msg}\n`);
  }, 120);
  return {
    stop(doneMsg) {
      clearInterval(id);
      process.stdout.write(`${c.up}${c.clearLine}\r  ${c.green}✓${c.reset} ${doneMsg}\n`);
    },
    fail(failMsg) {
      clearInterval(id);
      process.stdout.write(`${c.up}${c.clearLine}\r  ${c.red}✗${c.reset} ${failMsg}\n`);
    },
  };
}

function appPlist() {
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.agents-island.app</string>
    <key>CFBundleName</key>
    <string>Agents Island</string>
    <key>CFBundleExecutable</key>
    <string>island</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>Agents Island focuses the terminal tab a session is running in when you click it.</string>
</dict>
</plist>`;
}

function launchAgentPlist() {
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${PLIST_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${path.join(MACOS_DIR, "island")}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
</dict>
</plist>`;
}

function findLocalCodesignIdentity() {
  try {
    const out = execFileSync("/usr/bin/security", ["find-identity", "-v", "-p", "codesigning"], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
    });
    return out.includes(`"${LOCAL_CODESIGN_NAME}"`) ? LOCAL_CODESIGN_NAME : "";
  } catch {
    return "";
  }
}

function codesignIdentity() {
  return process.env.AGENTS_ISLAND_CODESIGN_IDENTITY || findLocalCodesignIdentity() || "-";
}

function signApp(appPath) {
  const identity = codesignIdentity();
  execFileSync("/usr/bin/codesign", ["--force", "--deep", "--sign", identity, appPath], { stdio: "pipe" });
  return identity;
}

function moveDir(src, dest) {
  try {
    fs.renameSync(src, dest);
  } catch (e) {
    if (e.code !== "EXDEV") throw e;
    fs.cpSync(src, dest, { recursive: true });
    fs.rmSync(src, { recursive: true, force: true });
  }
}

function stopAgent() {
  const uid = process.getuid();
  try { execFileSync("/bin/launchctl", ["bootout", `gui/${uid}/${PLIST_LABEL}`], { stdio: "pipe" }); } catch {}
  try { execFileSync("/bin/launchctl", ["unload", "-w", PLIST_PATH], { stdio: "pipe" }); } catch {}
}

function startAgent() {
  const uid = process.getuid();
  try {
    execFileSync("/bin/launchctl", ["bootstrap", `gui/${uid}`, PLIST_PATH], { stdio: "pipe" });
    return true;
  } catch {
    try {
      execFileSync("/bin/launchctl", ["load", "-w", PLIST_PATH], { stdio: "pipe" });
      return true;
    } catch {
      return false;
    }
  }
}

function buildStagedApp() {
  const stageRoot = fs.mkdtempSync(path.join(os.tmpdir(), "agents-island-build-"));
  const stagedApp = path.join(stageRoot, "AgentsIsland.app");
  const stagedMacOS = path.join(stagedApp, "Contents", "MacOS");

  fs.mkdirSync(stagedMacOS, { recursive: true });
  fs.writeFileSync(path.join(stagedApp, "Contents", "Info.plist"), appPlist());

  execFileSync("swiftc", ["-O", "-o", path.join(stagedMacOS, "island"), ISLAND_SRC, "-framework", "Cocoa", "-framework", "SwiftUI"], { stdio: "pipe" });
  execFileSync("swiftc", ["-O", "-o", path.join(stagedMacOS, "island-send"), SEND_SRC, "-framework", "Foundation"], { stdio: "pipe" });

  const hookDest = path.join(stagedMacOS, "island-hook.py");
  fs.copyFileSync(HOOK_SRC, hookDest);
  fs.chmodSync(hookDest, 0o755);

  const statuslineDest = path.join(stagedMacOS, "island-statusline.py");
  fs.copyFileSync(STATUSLINE_SRC, statuslineDest);
  fs.chmodSync(statuslineDest, 0o755);

  const signedWith = signApp(stagedApp);
  return { stageRoot, stagedApp, signedWith };
}

// ── Install ─────────────────────────────────────────────────────────────

// Remove a pre-rename ("Claude Island") install so it can't run beside the new one. The hooks
// aren't touched here — configureHooks already replaces old island-hook entries in place (MINE
// still matches them), so migrating them would double-remove. Best-effort throughout.
function migrateFromLegacy() {
  let found = false;
  const uid = process.getuid();
  try { execFileSync("/bin/launchctl", ["bootout", `gui/${uid}/${LEGACY.label}`], { stdio: "pipe" }); found = true; } catch {}
  for (const p of [LEGACY.plist, LEGACY.app, LEGACY.eventDir]) {
    if (fs.existsSync(p)) { try { fs.rmSync(p, { recursive: true, force: true }); found = true; } catch {} }
  }
  if (found) done("Removed the old Claude Island install");
}

async function install() {
  console.log(LOGO);
  hr();
  log();

  // Migrate ONLY when we'll also rewrite the hooks (i.e. not --no-hooks). Removing the old app
  // without repointing hooks that still target it would orphan them (/bin/sh: …/ClaudeIsland.app/
  // …/island-hook.py: No such file). A --no-hooks rebuild is for an already-installed AgentsIsland
  // anyway, where there's nothing to migrate.
  if (!process.argv.includes("--no-hooks")) migrateFromLegacy();

  // Step 1: Build
  log(`${c.dim}Step 1 of 3${c.reset}  ${c.white}Build${c.reset}`);
  log();

  let staged = null;
  const sp = spinner("Compiling native app...\n");
  try {
    staged = buildStagedApp();
    sp.stop("Compiled daemon + sender");
  } catch (e) {
    sp.fail("Compilation failed");
    if (staged?.stageRoot) fs.rmSync(staged.stageRoot, { recursive: true, force: true });
    log();
    info("Make sure Xcode Command Line Tools are installed:");
    info("  xcode-select --install");
    process.exit(1);
  }

  if (staged.signedWith === "-") {
    done("Signed (ad-hoc)");
    warn("Ad-hoc signing can make macOS ask for permissions again after each rebuild");
    info(`Create a local Code Signing identity named "${LOCAL_CODESIGN_NAME}" or set AGENTS_ISLAND_CODESIGN_IDENTITY to keep permissions stable.`);
  } else {
    done(`Signed (${staged.signedWith})`);
  }

  // Step 2: Background agent
  log();
  hr();
  log();
  log(`${c.dim}Step 2 of 3${c.reset}  ${c.white}Background agent${c.reset}`);
  log();

  fs.mkdirSync(LAUNCH_AGENTS, { recursive: true });
  fs.mkdirSync(EVENT_DIR, { recursive: true });

  // Copy the icons (animated .gif + still .tiff) into the (TCC-safe) event dir the daemon reads from.
  try {
    for (const icon of fs.readdirSync(ASSETS_DIR).filter((f) => f.endsWith(".gif") || f.endsWith(".tiff") || f.endsWith(".png"))) {
      fs.copyFileSync(path.join(ASSETS_DIR, icon), path.join(EVENT_DIR, icon));
    }
    done("Copied icons");
  } catch {}
  fs.mkdirSync(APP_DIR, { recursive: true });
  fs.writeFileSync(PLIST_PATH, launchAgentPlist());
  done("Installed LaunchAgent (auto-starts on login)");

  // Swap the app only after the staged build is known-good. This keeps the old island
  // running until the last possible moment, and keeps compile failures from unloading it.
  const backupPath = fs.existsSync(APP_PATH)
    ? path.join(APP_DIR, `.AgentsIsland.previous-${Date.now()}.app`)
    : "";
  const swap = spinner("Installing staged app...\n");
  try {
    stopAgent();
    if (backupPath) moveDir(APP_PATH, backupPath);
    moveDir(staged.stagedApp, APP_PATH);
    fs.rmSync(staged.stageRoot, { recursive: true, force: true });
    swap.stop("Installed app bundle");
  } catch (e) {
    swap.fail("Could not replace the installed app");
    if (staged?.stageRoot) fs.rmSync(staged.stageRoot, { recursive: true, force: true });
    if (backupPath && fs.existsSync(backupPath) && !fs.existsSync(APP_PATH)) moveDir(backupPath, APP_PATH);
    startAgent();
    log();
    warn(e.message || String(e));
    process.exit(1);
  }

  if (startAgent()) {
    done("Launched — island is live in your notch");
    if (backupPath) fs.rmSync(backupPath, { recursive: true, force: true });
  } else {
    warn("Could not launch new build; rolling back to previous app");
    stopAgent();
    if (backupPath && fs.existsSync(backupPath)) {
      if (fs.existsSync(APP_PATH)) fs.rmSync(APP_PATH, { recursive: true, force: true });
      moveDir(backupPath, APP_PATH);
      if (startAgent()) done("Rolled back and relaunched previous island");
    }
    process.exit(1);
  }

  // Step 3: Hooks
  log();
  hr();
  log();
  log(`${c.dim}Step 3 of 3${c.reset}  ${c.white}Hooks${c.reset}`);
  log();

  const hookDest = path.join(MACOS_DIR, "island-hook.py");
  const statuslineDest = path.join(MACOS_DIR, "island-statusline.py");
  let autoConfig = "";
  if (process.argv.includes("--no-hooks")) {
    autoConfig = "n";
    info("Skipping hook configuration (--no-hooks).");
  } else if (process.argv.includes("--yes") || process.argv.includes("-y")) {
    autoConfig = "y";
  } else {
    autoConfig = await ask(`Auto-configure Claude Code hooks? ${c.dim}(Y/n)${c.reset} `);
  }
  // The app is already built, swapped in, and running by this point, so a settings.json we
  // can't parse is not a reason to die — it's a reason to leave the file alone and say so.
  let hooksWired = true;
  if (autoConfig.toLowerCase() !== "n") {
    if (configureHooks(hookDest, statuslineDest)) {
      done("Updated ~/.claude/settings.json");
    } else {
      hooksWired = false;
      warn("Couldn't parse ~/.claude/settings.json — left it untouched");
      info("Fix the JSON there and re-run install, or add these yourself:");
      printManualHooks(hookDest);
    }
  } else {
    log();
    info("Add these hooks to ~/.claude/settings.json (see README).");
  }

  // Finale
  log();
  hr();
  log();
  if (!hooksWired) {
    console.log(`  ${c.orange}◆${c.reset} ${c.bold}${c.white}Island is live — but it can't see Claude yet.${c.reset}`);
    log();
    info("Nothing reaches the notch until those hooks are in place.");
    log();
    return;
  }
  console.log(`  ${c.orange}◆${c.reset} ${c.bold}${c.white}You're all set!${c.reset}`);
  log();
  info(`Test it: ${c.white}npx agents-island test${c.reset}`);
  log();
  info(`${c.dim}The pill shows a live spinner while Claude works, expands${c.reset}`);
  info(`${c.dim}when it needs you, and collapses to ✓ when it's done.${c.reset}`);
  log();
}

// ── Hook config ───────────────────────────────────────────────────────────

// Read Claude's settings. `{}` when there's no file yet; null when there IS one and it doesn't
// parse — callers must treat null as "hands off" rather than falling back to `{}`, or we'd
// replace a settings file we couldn't read with one containing nothing but our own hooks.
function readSettings() {
  if (!fs.existsSync(SETTINGS_PATH)) return {};
  try {
    return JSON.parse(fs.readFileSync(SETTINGS_PATH, "utf-8"));
  } catch {
    return null;
  }
}

const BACKUP_PREFIX = "settings.json.island-backup-";
const KEEP_BACKUPS = 3;   // enough to recover a bad edit; not enough to litter ~/.claude/

// Write settings back, keeping a timestamped copy of what was there first. This file is the
// user's, and the one thing in this install we can't recreate for them if we get it wrong. We
// then prune to the newest KEEP_BACKUPS so repeated installs don't pile up copies forever.
function writeSettings(settings) {
  const dir = path.dirname(SETTINGS_PATH);
  fs.mkdirSync(dir, { recursive: true });
  if (fs.existsSync(SETTINGS_PATH)) {
    fs.copyFileSync(SETTINGS_PATH, path.join(dir, `${BACKUP_PREFIX}${Date.now()}`));
    pruneBackups(dir);
  }
  fs.writeFileSync(SETTINGS_PATH, JSON.stringify(settings, null, 2) + "\n");
}

// Keep only the newest KEEP_BACKUPS island backups; delete the rest. Best-effort — a backup we
// can't remove is harmless, so never let cleanup failure break an install.
function pruneBackups(dir) {
  try {
    const old = fs.readdirSync(dir)
      .filter((f) => f.startsWith(BACKUP_PREFIX))
      .sort()                       // timestamp-suffixed → lexicographic == chronological
      .slice(0, -KEEP_BACKUPS);
    for (const f of old) {
      try { fs.unlinkSync(path.join(dir, f)); } catch {}
    }
  } catch {}
}

// Print what we would have written, for when we can't touch settings.json ourselves.
function printManualHooks(hookDest) {
  log();
  for (const [event, arg] of Object.entries(HOOK_EVENTS)) {
    log(`  ${c.dim}"${event}": [{ "matcher": "*", "hooks": [{ "type": "command", "command": "\\"${hookDest}\\" ${arg}" }] }]${c.reset}`);
  }
  log();
}

// Returns false if settings.json exists but couldn't be parsed (nothing was written).
function configureHooks(hookDest, statuslineDest) {
  const settings = readSettings();
  if (settings === null) return false;
  if (!settings.hooks) settings.hooks = {};

  // Statusline feed: the ONLY supported source for the live plan rate-limit % (5h / 7d), captured
  // to ~/.agents-island/ for the notch peek. Only claim the statusLine slot if it's empty or
  // already ours — never clobber a status line the user wrote themselves.
  if (statuslineDest) {
    const cur = settings.statusLine?.command || "";
    const ours = /island-statusline|AgentsIsland/.test(cur);
    if (!settings.statusLine || ours) {
      settings.statusLine = { type: "command", command: `"${statuslineDest}"`, padding: 0 };
    }
  }

  const hook = (event) => ({
    matcher: "*",
    hooks: [{ type: "command", command: `"${hookDest}" ${event}` }],
  });

  // Replace prior agents-island hooks and migrate off the old banner-based
  // notifier (ClaudeNotify/ClaudeCodeNotification), preserving everything else.
  const strip = (arr) =>
    (arr || []).filter(
      (n) => !n.hooks?.some((h) => MINE.test(h.command || ""))
    );

  for (const [event, arg] of Object.entries(HOOK_EVENTS)) {
    settings.hooks[event] = [...strip(settings.hooks[event]), hook(arg)];
  }

  writeSettings(settings);
  return true;
}

// ── Helpers ─────────────────────────────────────────────────────────────

function ask(question) {
  if (!process.stdin.isTTY) {
    console.log(`  ${c.orange}?${c.reset} ${question}${c.dim}Y${c.reset}`);
    return Promise.resolve("");
  }
  const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
  return new Promise((resolve) =>
    rl.question(`  ${c.orange}?${c.reset} ${question}`, (ans) => { rl.close(); resolve(ans.trim()); })
  );
}

// ── Uninstall ───────────────────────────────────────────────────────────

// Strip every island-owned hook and our statusline out of a settings object, IN PLACE. Only
// removes entries whose command matches MINE, and only deletes an event array once it's empty —
// a user's own hooks under the same event are left untouched. Returns true if anything changed.
// Pure (no I/O), so the destructive path is unit-testable without launchctl/fs side effects.
function stripIslandFromSettings(settings) {
  let removed = false;
  for (const event of Object.keys(HOOK_EVENTS)) {
    const cur = settings.hooks?.[event];
    if (!cur) continue;
    const kept = cur.filter((n) => !n.hooks?.some((h) => MINE.test(h.command || "")));
    if (kept.length === cur.length) continue;   // nothing of ours here — don't touch it
    if (kept.length) settings.hooks[event] = kept;
    else delete settings.hooks[event];
    removed = true;
  }
  if (settings.hooks && Object.keys(settings.hooks).length === 0) delete settings.hooks;
  if (/island-statusline|AgentsIsland/.test(settings.statusLine?.command || "")) {
    delete settings.statusLine;
    removed = true;
  }
  return removed;
}

function uninstall() {
  console.log(LOGO);
  hr();
  log();

  stopAgent();
  if (fs.existsSync(PLIST_PATH)) {
    fs.unlinkSync(PLIST_PATH);
    done("Removed LaunchAgent");
  }

  if (fs.existsSync(APP_PATH)) {
    fs.rmSync(APP_PATH, { recursive: true });
    done("Removed ~/Applications/AgentsIsland.app");
  }
  if (fs.existsSync(EVENT_DIR)) {
    fs.rmSync(EVENT_DIR, { recursive: true });
    done("Removed ~/.agents-island");
  }

  // Everything above is ours to delete outright. settings.json isn't — so if it won't parse,
  // say so and leave it rather than guessing at its contents.
  const settings = readSettings();
  if (settings === null) {
    warn("Couldn't parse ~/.claude/settings.json — remove the island hooks there by hand");
  } else if (stripIslandFromSettings(settings)) {
    writeSettings(settings);
    done("Removed hooks/statusline from ~/.claude/settings.json");
  }

  log();
  console.log(`  ${c.orange}◆${c.reset} ${c.bold}${c.white}Uninstalled.${c.reset} ${c.dim}Thanks for trying agents-island!${c.reset}`);
  log();
}

// ── Test ────────────────────────────────────────────────────────────────

async function test() {
  const send = path.join(MACOS_DIR, "island-send");
  if (!fs.existsSync(send)) {
    warn(`Not installed. Run: ${c.white}npx agents-island install${c.reset}`);
    process.exit(1);
  }

  // The daemon only ever reloads from ~/.agents-island/sessions/<id>.json (one file per live
  // session) — it never reads the legacy bare event.json that island-send defaults to. Target
  // "sessions/local.json" explicitly so this actually reaches IslandState. "local" is also the
  // one id that's always visible regardless of live-tab tracking (see `visibleSessions`).
  const push = (payload) => {
    const child = spawn(send, ["sessions/local.json"], { stdio: ["pipe", "ignore", "ignore"] });
    child.stdin.write(JSON.stringify(payload));
    child.stdin.end();
  };

  const project = path.basename(process.cwd());
  const base = { id: "local", project, aiTitle: `Claude Code · ${project}`, cwd: process.cwd() };
  const now = () => Math.floor(Date.now() / 1000);

  log();
  info("Running through the states — watch your notch…");

  // kind: "prompt" seeds turnStartTs so the later "done" state shows a real elapsed timer.
  push({ ...base, mode: "working", detail: "Working…", kind: "prompt", ts: now() });
  await sleep(2200);
  push({ ...base, mode: "attention", detail: "Needs your permission to run a command", kind: "attention", ts: now() });
  await sleep(2600);
  push({ ...base, mode: "done", preview: "All done — tests passing", kind: "stop", ts: now() });

  // The "local" session is ALWAYS visible (it's the no-Warp-uuid fallback id), so a left-behind
  // local.json lingers as a phantom card forever. Let the user watch the "done" state land, then
  // delete the file — the daemon's reload() prunes any session whose file disappeared.
  await sleep(3500);
  try { fs.rmSync(path.join(EVENT_DIR, "sessions", "local.json")); } catch {}

  log();
  done("Sent test sequence");
  log();
}

// ── Doctor ──────────────────────────────────────────────────────────────

// A pasteable health report. When the island "doesn't work" for someone, this turns a vague
// report into a concrete one: what's missing (a toolchain, the daemon, the hooks) and the exact
// next step. Read-only — it never changes anything.
function doctor() {
  console.log(LOGO);
  hr();
  log();

  const has = (bin) => {
    try { execFileSync("/usr/bin/which", [bin], { stdio: "pipe" }); return true; } catch { return false; }
  };
  const running = () => {
    try {
      const out = execFileSync("/usr/bin/pgrep", ["-f", `${APP_PATH}/Contents/MacOS/island`], { encoding: "utf8", stdio: "pipe" });
      return out.trim().length > 0;
    } catch { return false; }
  };
  const line = (ok, label, hint) => {
    (ok ? done : warn)(label);
    if (!ok && hint) info(`  → ${hint}`);
  };

  // Toolchain the installer/hook depend on.
  line(has("swiftc"), "Swift compiler (swiftc)", "xcode-select --install");
  line(has("python3"), "python3 (runs the hook)", "comes with Xcode Command Line Tools");

  // The app + background agent.
  line(fs.existsSync(path.join(MACOS_DIR, "island")), "App compiled", "npx agents-island install");
  line(fs.existsSync(PLIST_PATH), "LaunchAgent installed", "npx agents-island install");
  line(running(), "Daemon running", "npx agents-island install, or check Console.app for com.agents-island");
  line(fs.existsSync(EVENT_DIR), "State dir ~/.agents-island", "npx agents-island install");

  // Hooks — the only thing that feeds the island. Parse defensively.
  const settings = readSettings();
  if (settings === null) {
    warn("~/.claude/settings.json — can't parse");
    info("  → fix the JSON, then re-run install");
  } else {
    const wired = Object.keys(HOOK_EVENTS).filter((e) =>
      (settings.hooks?.[e] || []).some((n) => n.hooks?.some((h) => /island-hook/.test(h.command || "")))
    );
    line(wired.length === Object.keys(HOOK_EVENTS).length,
      `Hooks wired (${wired.length}/${Object.keys(HOOK_EVENTS).length})`,
      "npx agents-island install  (answer Yes to configure hooks)");
    line(/island-statusline/.test(settings.statusLine?.command || ""),
      "Statusline wired (usage %)",
      "optional — only powers the notch usage peek");
  }

  log();
  hr();
  log();
  info("Paste this output into an issue if something's off:");
  info("https://github.com/narulakeshav/agents-island/issues");
  log();
}

// ── CLI ─────────────────────────────────────────────────────────────────

function runCLI() {
  switch (process.argv[2]) {
    case "install":   install(); break;
    case "uninstall": uninstall(); break;
    case "test":      test(); break;
    case "doctor":    doctor(); break;
    default:
      console.log(LOGO);
      hr();
      log();
      log(`${c.white}Usage:${c.reset}`);
      log();
      log(`  ${c.orange}install${c.reset}     Set up the notch island`);
      log(`  ${c.orange}install --no-hooks${c.reset}  Rebuild/relaunch without touching Claude settings`);
      log(`  ${c.orange}test${c.reset}        Run through the states`);
      log(`  ${c.orange}doctor${c.reset}      Diagnose a broken install`);
      log(`  ${c.orange}uninstall${c.reset}   Remove everything`);
      log();
      info(`npx agents-island install`);
      log();
  }
}

// Run the CLI only when invoked directly; when required (by the tests) just expose the
// internals so the settings logic can be exercised without the launchctl/swiftc side effects.
if (require.main === module) {
  runCLI();
} else {
  module.exports = {
    MINE, HOOK_EVENTS, SETTINGS_PATH,
    readSettings, writeSettings, configureHooks, stripIslandFromSettings,
  };
}
