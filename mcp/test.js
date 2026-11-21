#!/usr/bin/env node
// Tests the connector the way the Claude desktop app uses it, against a SEPARATE Cutgenie on port 7879.
//   node mcp/test.js        (build first: swift build -c release; needs ffmpeg)
// Your own Cutgenie (port 7878), projects and media are never touched.
"use strict";
const { spawn, execFileSync } = require("child_process");
const fs = require("fs"), os = require("os"), path = require("path");
const root = path.resolve(__dirname, "..");
const W = fs.mkdtempSync(path.join("/tmp", "cutgenie-mcp-"));
const env = { ...process.env, CUTGENIE_PORT: "7879", CUTGENIE_AWAKE: "1", CUTGENIE_LIBRARY: path.join(W, "lib.json") };
try { execFileSync("zsh", ["-c", "for p in $(lsof -nP -iTCP:7879 -sTCP:LISTEN -t); do kill $p; done"]); } catch {}
const app = spawn(path.join(root, ".build/release/Cutgenie"), [], { env, stdio: "ignore" });
const ff = (...a) => execFileSync("ffmpeg", ["-v", "error", "-y", ...a]);
ff("-f", "lavfi", "-i", "testsrc2=s=1920x1080:r=30:d=6", "-f", "lavfi", "-i", "sine=f=440:d=2,apad=pad_dur=2,volume=1", "-t", "6", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", path.join(W, "a.mp4"));
const srv = spawn("node", [path.join(root, "mcp/server/index.js")], { env: { ...env } });
let buf = "", waiting = {}, nid = 0;
srv.stdout.on("data", (c) => { buf += c; let i; while ((i = buf.indexOf("\n")) >= 0) { const m = JSON.parse(buf.slice(0, i)); buf = buf.slice(i + 1); waiting[m.id] && waiting[m.id](m); } });
const rpc = (method, params) => new Promise((r) => { const id = ++nid; waiting[id] = r; srv.stdin.write(JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n"); });
const tool = async (name, args) => (await rpc("tools/call", { name, arguments: args })).result;
let pass = 0, fail = 0;
const check = (label, ok, info = "") => { ok ? pass++ : fail++; console.log(`${ok ? "ok  " : "FAIL"} ${label}${ok ? "" : "  -> " + info}`); };
const txt = (r) => (r.content || []).map((c) => c.text || `[${c.type}]`).join(" ");
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
(async () => {
  for (let i = 0; i < 40; i++) { try { execFileSync("zsh", ["-c", "lsof -nP -iTCP:7879 -sTCP:LISTEN -t"]); break; } catch { await sleep(500); } }
  await sleep(2000);
  const init = await rpc("initialize", { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "test", version: "1" } });
  check("initialize", init.result && init.result.serverInfo.name === "cutgenie" && /Safety rules/.test(init.result.instructions));
  srv.stdin.write(JSON.stringify({ jsonrpc: "2.0", method: "notifications/initialized" }) + "\n");
  const list = await rpc("tools/list", {});
  check("tools/list has 9 tools", list.result.tools.length === 9, list.result.tools.length);
  let r = await tool("cutgenie_status", {}); check("status", !r.isError, txt(r));
  const proj = path.join(W, "Test.cutgenie.json");
  r = await tool("cutgenie_command", { command: "new_project", args: { path: proj, width: 1920, height: 1080, fps: 30 } }); check("new_project", !r.isError, txt(r));
  await sleep(2000);
  r = await tool("cutgenie_command", { command: "new_project", args: { path: proj } }); check("refuses new_project over an existing file", r.isError, txt(r));
  r = await tool("cutgenie_command", { command: "add_clip", args: { path: path.join(W, "a.mp4") } }); check("add_clip (saves first)", !r.isError, txt(r));
  check("a version was saved before the first edit", fs.existsSync(proj));
  r = await tool("cutgenie_command", { command: "add_clip", args: { path: path.join(W, "a.mp4") } }); check("add_clip 2", !r.isError, txt(r));
  r = await tool("cutgenie_get_project", {}); const p = JSON.parse(txt(r)); check("get_project summary", p.main_track.length === 2 && p.main_track[1].offset === 6, txt(r));
  r = await tool("cutgenie_find_silences", { path: path.join(W, "a.mp4") }); const s = JSON.parse(txt(r));
  check("find_silences finds the 2-4 s pause", s.pauses.length >= 1 && Math.abs(s.pauses[0].start - 2) < 0.2, txt(r));
  r = await tool("cutgenie_command", { command: "ripple_delete", args: { from: 8.15, to: 9.85 } }); check("ripple_delete", !r.isError, txt(r));
  r = await tool("cutgenie_undo", {}); check("undo", !r.isError, txt(r));
  r = await tool("cutgenie_command", { command: "add_text", args: { text: "Hello", at: 1, dur: 3, size: 90 } }); check("add_text", !r.isError, txt(r));
  r = await tool("cutgenie_command", { command: "set_zoom", args: { clip: "c1", keys: "0:1,5:1.1:s" } }); check("set_zoom", !r.isError, txt(r));
  r = await tool("cutgenie_command", { command: "set_color", args: { clip: "c2", exposure: 0.2 } }); check("set_color", !r.isError, txt(r));
  r = await tool("cutgenie_render_frame", { time: 2 }); check("render_frame returns an image", !r.isError && r.content[0].type === "image" && r.content[0].data.length > 1000, txt(r));
  r = await tool("cutgenie_command", { command: "quit" }); check("blocks quit", r.isError, txt(r));
  r = await tool("cutgenie_command", { command: "ui_key", args: { key: "z" } }); check("blocks testing aids", r.isError, txt(r));
  r = await tool("cutgenie_command", { command: "export", args: { out: path.join(W, "x.mp4") } }); check("blocks export via command", r.isError, txt(r));
  r = await tool("cutgenie_command", { command: "set_color", args: { clip: "c1", exposure: 0.1, overwrite: true } }); check("blocks overwrite args", r.isError, txt(r));
  const out = path.join(W, "out.mp4");
  r = await tool("cutgenie_export", { out, preset: "youtube", from: 0, to: 2 }); check("export", !r.isError && fs.existsSync(out), txt(r));
  r = await tool("cutgenie_export", { out, preset: "youtube", from: 0, to: 2 }); check("export refuses to replace without a yes", r.isError, txt(r));
  r = await tool("cutgenie_export", { out, preset: "compatible", from: 0, to: 2, replace_existing: true }); check("export replaces after a yes", !r.isError, txt(r));
  r = await tool("cutgenie_export", { out: path.join(W, "out.wav"), preset: "audio", from: 0, to: 2 }); check("export sound only", !r.isError, txt(r));
  check("original media unchanged", fs.statSync(path.join(W, "a.mp4")).size > 0);
  console.log(`\n${pass} of ${pass + fail} passed   (work folder ${W})`);
  srv.kill(); app.kill(); process.exit(fail ? 1 : 0);
})();
