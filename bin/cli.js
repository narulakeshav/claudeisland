#!/usr/bin/env node

const { execSync, spawn } = require("child_process");
const fs = require("fs");
const path = require("path");
const readline = require("readline");

const HOME = process.env.HOME;
const APP_DIR = path.join(HOME, "Applications");
const APP_PATH = path.join(APP_DIR, "ClaudeIsland.app");
const MACOS_DIR = path.join(APP_PATH, "Contents", "MacOS");
const ISLAND_SRC = path.join(__dirname, "..", "src", "island", "island.swift");
const SEND_SRC = path.join(__dirname, "..", "src", "island", "island-send.swift");
const HOOK_SRC = path.join(__dirname, "..", "src", "island", "island-hook.sh");
const SETTINGS_PATH = path.join(HOME, ".claude", "settings.json");
const LAUNCH_AGENTS = path.join(HOME, "Library", "LaunchAgents");
const PLIST_LABEL = "com.claude-island.app";
const PLIST_PATH = path.join(LAUNCH_AGENTS, `${PLIST_LABEL}.plist`);
const EVENT_DIR = path.join(HOME, ".claude-island");
const VERSION = require("../package.json").version;

// Matches hooks owned by this tool or the legacy banner notifier we migrate from.
const MINE = /claude-island|island-hook|ClaudeNotify|ClaudeCodeNotification|stop-hook/;

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

const titleBar = `─── ${c.reset}${c.bold}${c.white}claude-island${c.reset} ${c.dim}v${VERSION} `;
const titleVis = `─── claude-island v${VERSION} `;
const titlePad = "─".repeat(Math.max(0, W - titleVis.length));

const LOGO = `
${c.dim}╭${titleBar}${titlePad}╮${c.reset}
${c.dim}│${" ".repeat(W)}│${c.reset}
${c.dim}│${c.reset}${center(`${c.white}╭─────────╮${c.reset}`, W)}${c.dim}│${c.reset}
${c.dim}│${c.reset}${center(`${c.white}│ ${c.peach}◜◞${c.white}  ···· │${c.reset}`, W)}${c.dim}│${c.reset}
${c.dim}│${c.reset}${center(`${c.white}╰─────────╯${c.reset}`, W)}${c.dim}│${c.reset}
${c.dim}│${" ".repeat(W)}│${c.reset}
${c.dim}│${c.reset}${center(`${c.gray}A live activity in your notch for Claude Code${c.reset}`, W)}${c.dim}│${c.reset}
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

// ── Install ─────────────────────────────────────────────────────────────

async function install() {
  console.log(LOGO);
  hr();
  log();

  // Step 1: Build
  log(`${c.dim}Step 1 of 3${c.reset}  ${c.white}Build${c.reset}`);
  log();

  fs.mkdirSync(MACOS_DIR, { recursive: true });

  const plist = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.claude-island.app</string>
    <key>CFBundleName</key>
    <string>Claude Island</string>
    <key>CFBundleExecutable</key>
    <string>island</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>`;
  fs.writeFileSync(path.join(APP_PATH, "Contents", "Info.plist"), plist);

  const sp = spinner("Compiling native app...\n");
  try {
    execSync(`swiftc -O -o "${path.join(MACOS_DIR, "island")}" "${ISLAND_SRC}" -framework Cocoa -framework SwiftUI`, { stdio: "pipe" });
    execSync(`swiftc -O -o "${path.join(MACOS_DIR, "island-send")}" "${SEND_SRC}" -framework Foundation`, { stdio: "pipe" });
    sp.stop("Compiled daemon + sender");
  } catch (e) {
    sp.fail("Compilation failed");
    log();
    info("Make sure Xcode Command Line Tools are installed:");
    info("  xcode-select --install");
    process.exit(1);
  }

  const hookDest = path.join(MACOS_DIR, "island-hook.sh");
  fs.copyFileSync(HOOK_SRC, hookDest);
  fs.chmodSync(hookDest, 0o755);

  execSync(`codesign --force --deep --sign - "${APP_PATH}"`, { stdio: "pipe" });
  done("Signed (ad-hoc)");

  // Step 2: Background agent
  log();
  hr();
  log();
  log(`${c.dim}Step 2 of 3${c.reset}  ${c.white}Background agent${c.reset}`);
  log();

  fs.mkdirSync(LAUNCH_AGENTS, { recursive: true });
  fs.mkdirSync(EVENT_DIR, { recursive: true });
  const agentPlist = `<?xml version="1.0" encoding="UTF-8"?>
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
  fs.writeFileSync(PLIST_PATH, agentPlist);
  done("Installed LaunchAgent (auto-starts on login)");

  // (Re)load the agent.
  const uid = process.getuid();
  try { execSync(`launchctl bootout gui/${uid}/${PLIST_LABEL}`, { stdio: "pipe" }); } catch {}
  try {
    execSync(`launchctl bootstrap gui/${uid} "${PLIST_PATH}"`, { stdio: "pipe" });
    done("Launched — island is live in your notch");
  } catch (e) {
    // Fallback for older launchctl semantics.
    try {
      execSync(`launchctl load -w "${PLIST_PATH}"`, { stdio: "pipe" });
      done("Launched — island is live in your notch");
    } catch {
      warn("Could not auto-launch; it will start on next login");
    }
  }

  // Step 3: Hooks
  log();
  hr();
  log();
  log(`${c.dim}Step 3 of 3${c.reset}  ${c.white}Hooks${c.reset}`);
  log();

  const autoConfig = await ask(`Auto-configure Claude Code hooks? ${c.dim}(Y/n)${c.reset} `);
  if (autoConfig.toLowerCase() !== "n") {
    configureHooks(hookDest);
    done("Updated ~/.claude/settings.json");
  } else {
    log();
    info("Add these hooks to ~/.claude/settings.json (see README).");
  }

  // Finale
  log();
  hr();
  log();
  console.log(`  ${c.orange}◆${c.reset} ${c.bold}${c.white}You're all set!${c.reset}`);
  log();
  info(`Test it: ${c.white}npx claude-island test${c.reset}`);
  log();
  info(`${c.dim}The pill shows a live spinner while Claude works, expands${c.reset}`);
  info(`${c.dim}when it needs you, and collapses to ✓ when it's done.${c.reset}`);
  log();
}

// ── Hook config ───────────────────────────────────────────────────────────

function configureHooks(hookDest) {
  let settings = {};
  if (fs.existsSync(SETTINGS_PATH)) {
    settings = JSON.parse(fs.readFileSync(SETTINGS_PATH, "utf-8"));
  } else {
    fs.mkdirSync(path.dirname(SETTINGS_PATH), { recursive: true });
  }
  if (!settings.hooks) settings.hooks = {};

  const hook = (event) => ({
    matcher: "*",
    hooks: [{ type: "command", command: `"${hookDest}" ${event}` }],
  });

  // Replace prior claude-island hooks and migrate off the old banner-based
  // notifier (ClaudeNotify/ClaudeCodeNotification), preserving everything else.
  const strip = (arr) =>
    (arr || []).filter(
      (n) => !n.hooks?.some((h) => MINE.test(h.command || ""))
    );

  settings.hooks.UserPromptSubmit = [...strip(settings.hooks.UserPromptSubmit), hook("prompt")];
  settings.hooks.PreToolUse = [...strip(settings.hooks.PreToolUse), hook("tool")];
  settings.hooks.PostToolUse = [...strip(settings.hooks.PostToolUse), hook("post")];
  settings.hooks.Notification = [...strip(settings.hooks.Notification), hook("attention")];
  settings.hooks.Stop = [...strip(settings.hooks.Stop), hook("stop")];

  fs.writeFileSync(SETTINGS_PATH, JSON.stringify(settings, null, 2) + "\n");
}

// ── Helpers ─────────────────────────────────────────────────────────────

function ask(question) {
  const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
  return new Promise((resolve) =>
    rl.question(`  ${c.orange}?${c.reset} ${question}`, (ans) => { rl.close(); resolve(ans.trim()); })
  );
}

// ── Uninstall ───────────────────────────────────────────────────────────

function uninstall() {
  console.log(LOGO);
  hr();
  log();

  const uid = process.getuid();
  try { execSync(`launchctl bootout gui/${uid}/${PLIST_LABEL}`, { stdio: "pipe" }); } catch {}
  try { execSync(`launchctl unload -w "${PLIST_PATH}"`, { stdio: "pipe" }); } catch {}
  if (fs.existsSync(PLIST_PATH)) {
    fs.unlinkSync(PLIST_PATH);
    done("Removed LaunchAgent");
  }

  if (fs.existsSync(APP_PATH)) {
    fs.rmSync(APP_PATH, { recursive: true });
    done("Removed ~/Applications/ClaudeIsland.app");
  }
  if (fs.existsSync(EVENT_DIR)) {
    fs.rmSync(EVENT_DIR, { recursive: true });
    done("Removed ~/.claude-island");
  }

  if (fs.existsSync(SETTINGS_PATH)) {
    const settings = JSON.parse(fs.readFileSync(SETTINGS_PATH, "utf-8"));
    let removed = false;
    for (const event of ["UserPromptSubmit", "PreToolUse", "PostToolUse", "Notification", "Stop"]) {
      if (settings.hooks?.[event]) {
        settings.hooks[event] = settings.hooks[event].filter(
          (n) => !n.hooks?.some((h) => MINE.test(h.command || ""))
        );
        if (settings.hooks[event].length === 0) delete settings.hooks[event];
        removed = true;
      }
    }
    if (settings.hooks && Object.keys(settings.hooks).length === 0) delete settings.hooks;
    if (removed) {
      fs.writeFileSync(SETTINGS_PATH, JSON.stringify(settings, null, 2) + "\n");
      done("Removed hooks from ~/.claude/settings.json");
    }
  }

  log();
  console.log(`  ${c.orange}◆${c.reset} ${c.bold}${c.white}Uninstalled.${c.reset} ${c.dim}Thanks for trying claude-island!${c.reset}`);
  log();
}

// ── Test ────────────────────────────────────────────────────────────────

async function test() {
  const send = path.join(MACOS_DIR, "island-send");
  if (!fs.existsSync(send)) {
    warn(`Not installed. Run: ${c.white}npx claude-island install${c.reset}`);
    process.exit(1);
  }

  const push = (payload) => {
    const child = spawn(send, [], { stdio: ["pipe", "ignore", "ignore"] });
    child.stdin.write(JSON.stringify(payload));
    child.stdin.end();
  };

  const project = path.basename(process.cwd());
  log();
  info("Running through the states — watch your notch…");

  push({ mode: "working", title: `Claude Code · ${project}`, detail: "Working…" });
  await sleep(2200);
  push({ mode: "attention", title: `Claude Code · ${project}`, detail: "Needs your permission to run a command" });
  await sleep(2600);
  push({ mode: "done", title: `Claude Code · ${project}`, detail: "All done — tests passing" });

  log();
  done("Sent test sequence");
  log();
}

// ── CLI ─────────────────────────────────────────────────────────────────

const command = process.argv[2];

switch (command) {
  case "install":
    install();
    break;
  case "uninstall":
    uninstall();
    break;
  case "test":
    test();
    break;
  default:
    console.log(LOGO);
    hr();
    log();
    log(`${c.white}Usage:${c.reset}`);
    log();
    log(`  ${c.orange}install${c.reset}     Set up the notch island`);
    log(`  ${c.orange}test${c.reset}        Run through the states`);
    log(`  ${c.orange}uninstall${c.reset}   Remove everything`);
    log();
    info(`npx claude-island install`);
    log();
}
