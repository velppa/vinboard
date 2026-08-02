#!/usr/bin/env node
// Archive a page via Safari's MCP server (safaridriver --mcp): navigate,
// extract the rendered HTML, print it to stdout. Extra args are ignored.
import { spawn, execSync } from "node:child_process";
import readline from "node:readline";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const url = process.argv[2];
if (!url) {
  console.error("usage: safari-archive <url>");
  process.exit(2);
}

const DRIVER = process.env.SAFARI_MCP_DRIVER ||
  "/Applications/Safari Technology Preview.app/Contents/MacOS/safaridriver";

// Each safaridriver session launches its own "Safari Technology Preview
// --automation" instance and does not reap it when killed; snapshot the
// automation pids so any newcomer can be cleaned up on exit.
function automationPids() {
  try {
    return execSync("pgrep -f 'MacOS/Safari Technology Preview -ApplePersistenceIgnoreStateQuietly'", { encoding: "utf8" })
      .trim().split("\n").filter(Boolean).map(Number);
  } catch { return []; }
}
const preexisting = new Set(automationPids());

const p = spawn(DRIVER, ["--mcp"], { stdio: ["pipe", "pipe", "ignore"] });
const rl = readline.createInterface({ input: p.stdout });
const pending = new Map();
let nextId = 1;

rl.on("line", (line) => {
  let msg;
  try { msg = JSON.parse(line); } catch { return; }
  if (msg.id !== undefined && pending.has(msg.id)) {
    const { resolve, reject } = pending.get(msg.id);
    pending.delete(msg.id);
    if (msg.error) reject(new Error(JSON.stringify(msg.error)));
    else resolve(msg.result);
  }
});

function call(method, params) {
  return new Promise((resolve, reject) => {
    const id = nextId++;
    pending.set(id, { resolve, reject });
    p.stdin.write(JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n");
  });
}

function notify(method, params) {
  p.stdin.write(JSON.stringify({ jsonrpc: "2.0", method, params }) + "\n");
}

function toolText(result) {
  const c = (result.content || []).find((x) => x.type === "text");
  return c ? c.text : "";
}

const deadline = setTimeout(() => {
  console.error("safari-archive: timeout");
  p.kill();
  process.exit(1);
}, 150000);

let exitCode = 1;
let handle = null;
try {
  await call("initialize", {
    protocolVersion: "2025-06-18",
    capabilities: {},
    clientInfo: { name: "vinboard-archiver", version: "1.0" },
  });
  notify("notifications/initialized", {});

  const tab = await call("tools/call", { name: "create_tab", arguments: { url } });
  try { handle = JSON.parse(toolText(tab)).handle; } catch { /* keep null */ }

  await call("tools/call", { name: "wait_for_navigation", arguments: { timeout_seconds: 60 } });
  // Let script-rendered pages settle; load-complete fires before they paint content.
  await new Promise((r) => setTimeout(r, 3000));

  const tmp = path.join(os.tmpdir(), `safari-archive-${process.pid}.html`);
  await call("tools/call", {
    name: "get_page_content",
    arguments: {
      format: "html",
      region: "entire_page",
      maxWordsPerParagraph: 100000,
      shortenURLs: false,
      includeAccessibilityAttributes: false,
      nodeIds: "none",
      savePath: tmp,
    },
  });
  // The file holds {"format":"html","content":"..."}.
  const wrapper = JSON.parse(fs.readFileSync(tmp, "utf8"));
  fs.unlinkSync(tmp);
  const html = wrapper.content || "";
  // Near-empty extractions are failed loads, not archives.
  if (html.length < 50) throw new Error(`extraction too small (${html.length} bytes)`);
  process.stdout.write(html);
  exitCode = 0;
} catch (e) {
  console.error("safari-archive:", e.message);
} finally {
  clearTimeout(deadline);
  if (handle) {
    try { await call("tools/call", { name: "close_tab", arguments: { handle } }); } catch { /* closing anyway */ }
  }
  // Graceful first: EOF lets safaridriver tear its session down; then kill.
  try { p.stdin.end(); } catch { /* already gone */ }
  const exited = new Promise((r) => p.once("exit", r));
  await Promise.race([exited, new Promise((r) => setTimeout(r, 3000))]);
  p.kill();
  for (const pid of automationPids()) {
    if (!preexisting.has(pid)) {
      try { process.kill(pid); } catch { /* already gone */ }
    }
  }
  process.exit(exitCode);
}
