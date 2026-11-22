#!/usr/bin/env node
// Cutgenie connector for the Claude desktop app (an MCP server over stdio, no dependencies).
// It forwards Claude's requests to a running Cutgenie on 127.0.0.1 (port CUTGENIE_PORT, default 7878)
// and enforces the same safety rules as the Claude Code skills in skills/.
"use strict";
const http = require("http");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { execFile } = require("child_process");

const PORT = Number(process.env.CUTGENIE_PORT || 7878);
const VERSION = "0.1.0";

// ---------- talking to Cutgenie ----------
function cutgenie(cmd, args = {}) {
  return new Promise((resolve) => {
    const body = JSON.stringify({ cmd, ...args });
    const req = http.request({ host: "127.0.0.1", port: PORT, path: "/command", method: "POST",
      headers: { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(body) }, timeout: 600000 },
      (res) => { let d = ""; res.on("data", (c) => (d += c)); res.on("end", () => {
        try { resolve(JSON.parse(d)); } catch { resolve({ ok: false, error: "unexpected reply from Cutgenie: " + d.slice(0, 200) }); }
      }); });
    req.on("error", () => resolve({ ok: false, error: `Cutgenie is not reachable on port ${PORT}. Ask the person to open Cutgenie (and a project), then try again.` }));
    req.on("timeout", () => { req.destroy(); resolve({ ok: false, error: "Cutgenie took too long to answer." }); });
    req.write(body); req.end();
  });
}

// ---------- safety ----------
// Commands that only read: they never need a save first.
const READ_ONLY = new Set(["status", "get_project", "lib_list", "list_looks", "list_audio_presets", "analyze_audio",
  "render_frame", "magnetic_drop_x", "pause", "play", "seek", "next_marker", "previous_marker", "zoom", "show",
  "audio_track", "copy", "copy_grade", "play_speed", "playback_scale", "shuttle"]);
// Never sent through the general command tool.
const BLOCKED = {
  quit: "Closing Cutgenie is left to the person.",
  export: "Use the cutgenie_export tool, which checks for existing files.",
  set_asset_paths: "Changing where media files point is only done by Collect media in the app.",
  delete_look: "Deleting saved looks is left to the person (Color tab ▸ Looks).",
  delete_title: "Deleting saved titles is left to the person (Graphics ▸ Add title ▸ Delete title).",
  delete_audio_preset: "Deleting audio presets is left to the person (Audio tab ▸ Presets).",
  set_display: "Window display settings are left to the person.",
};
const TESTING = /^(ui_|probe_|pointer_png|snapshot_ui|live_bench|fx_stats|mix_check|audio_debug|convert_probe|segments|skim|scroll_by|inspector_tab)/;
let savedThisSession = false;
async function saveFirst() {
  if (savedThisSession) return null;
  const st = await cutgenie("status");
  if (!st.ok) return st.error;
  if (!st.path) return "This project has never been saved. Ask the person where to save it, then use cutgenie_command with command \"save\" and args {\"path\": \"<folder>/<name>.cutgenie.json\"} before editing.";
  const r = await cutgenie("save");
  if (!r.ok) return "Could not save a version before editing: " + r.error;
  savedThisSession = true;
  return null;
}
const exists = (p) => { try { return fs.existsSync(p.replace(/^~(?=\/|$)/, os.homedir())); } catch { return false; } };

// ---------- tools ----------
const RULES = `Safety rules for editing in Cutgenie (always follow them):
1. Never touch original media: never move, rename, re-encode, overwrite or delete the person's video, sound or image files. Edits live only in the project.
2. A version is saved automatically before your first edit (the connector does this). Cutgenie keeps the last 10 versions (Versions… in the app).
3. If an edit does something unexpected, call cutgenie_undo (once per step) and check with cutgenie_get_project before trying again. Never fix forward on top of a wrong edit.
4. Never replace an existing export unless the person said yes to replacing that exact file (cutgenie_export replace_existing).
5. Say what you will do, work in small steps, check the project after each group of edits, and tell the person what changed and how to undo it (⌘Z or Versions…).`;

const GUIDE = `Cutgenie is a macOS video editor. Times are seconds on the timeline. Clip ids: V1 clips c1, c2…; graphics g1…; sound-only clips in audioClips.
Common commands for cutgenie_command (args as an object):
- Clips: add_clip {path}, split {at}, blade_all {at}, trim {clip, edge: start|end, to}, ripple_delete {clip} or {from, to}, delete {clip} (leaves a gap), move_items {ids, delta}, roll {at, delta}, slip {clip, delta}, set_speed {clip, speed}, to_lane {clip, lane: 1, at}.
- Remove pauses: call cutgenie_find_silences on each V1 clip's file, convert source times to timeline times (timeline = offset + (source − sourceIn)), keep ~0.15 s on each side, and ripple_delete {from, to} from the END of the timeline backwards.
- Place by what is said: cutgenie_transcribe {clip: "c1"} (runs on the Mac; never ask for the video to be attached or work on it in your own sandbox) gives every word with source times; convert to timeline times the same way and put the title, lower third or zoom there (start ~0.2 s early). Ask before downloading a model: base 150 MB is fine for clear English; offer large (1.6 GB) for Hindi, Hinglish or other languages. Long files: transcribe about 5 minutes at a time (from/to).
- Titles: add_text {text, at, dur, size} → id; text_edit {id, text, font, size, bold, color: "r,g,b,a", stroke_width, stroke_color}; layer_set {ids, x, y, scale, fade_in, fade_out} (px from centre, y up); add_shape {kind: rect|circle|line|solid|gradient|blur, at, dur}; layer_fx {ids, type: shadow|glow|stroke|corners|blur|color|tint}. For a name above a job title use two text layers.
- Zoom (V1): set_zoom {clip, keys: "t:scale[:ease],…"} (t from the clip's start, 1.1 = 10 % closer, ease linear|in|out|s; keys "" removes). Picture in picture (V2+): to_lane then pip {clip, x, y, scale}.
- Blur: add_shape {kind: blur, at, dur} then layer_set {ids, x, y}; follow movement with layer_set {ids, at, x, y} at several times; check frames with cutgenie_render_frame.
- Sound: set_volume {id, gain_db}, set_fade {id, in, out}, add_audio {path, at}; per track: audio_track {track: A1}, set_eq {band, type: highpass|lowpass|bell|lowshelf|highshelf|notch, freq, gain, q}, set_gate {enabled, threshold, range}, set_comp {enabled, threshold, ratio, makeup}, set_limiter {enabled, ceiling}; analyze_audio, match_loudness {target: -14}.
- Colour: set_color {clip, exposure, contrast, saturation, temperature, tint} (neutral 0,1,1,0,0), set_wheels {clip, wheel, hue, amount}, set_lut {clip, slot: input|creative, path}, copy_grade {clip} + paste_grade {ids}, save_look/apply_look {name}.
- Projects: new_project {path, width, height, fps}, open {path}, duplicate_project {path, vertical: true}, restore_version {file}, relink_folder {dir}.
The full list is in the Cutgenie docs (Reference ▸ Control commands).`;

const TOOLS = [
  { name: "cutgenie_status", description: "Check that Cutgenie is open and which project is loaded (name, file, clip count, length, can undo/redo). Call this first.",
    inputSchema: { type: "object", properties: {} } },
  { name: "cutgenie_get_project", description: "Read the open project: clips on the main track (id, file, start on the timeline, length, source in-point), clips on upper tracks, graphics, sound clips and markers. Set full=true for the complete project JSON.",
    inputSchema: { type: "object", properties: { full: { type: "boolean", description: "Return the full project JSON instead of a summary." } } } },
  { name: "cutgenie_command", description: "Run one Cutgenie editing command, e.g. split, trim, ripple_delete, add_text, set_zoom, set_color, set_volume. A version of the project is saved automatically before the first edit. See the server instructions for the commands and their arguments.",
    inputSchema: { type: "object", required: ["command"], properties: {
      command: { type: "string", description: "Command name, e.g. \"ripple_delete\"." },
      args: { type: "object", description: "Arguments, e.g. {\"from\": 12.5, \"to\": 13.9}.", additionalProperties: true } } } },
  { name: "cutgenie_undo", description: "Undo the last edit (one step). Use it when an edit came out wrong.", inputSchema: { type: "object", properties: {} } },
  { name: "cutgenie_redo", description: "Redo the last undone edit.", inputSchema: { type: "object", properties: {} } },
  { name: "cutgenie_save", description: "Save the project. Cutgenie keeps the replaced file as a version (the last 10).", inputSchema: { type: "object", properties: {} } },
  { name: "cutgenie_render_frame", description: "Render the edited picture at a time and return it as an image, to check a title, blur, zoom or colour change.",
    inputSchema: { type: "object", required: ["time"], properties: { time: { type: "number", description: "Seconds on the timeline." } } } },
  { name: "cutgenie_find_silences", description: "Find silent pauses in a media file with ffmpeg (read only; the file is never changed). Returns pauses as source-file times; convert them to timeline times before cutting.",
    inputSchema: { type: "object", required: ["path"], properties: {
      path: { type: "string", description: "The clip's media file." },
      noise_db: { type: "number", description: "Quieter than this counts as silence (default -35)." },
      min_seconds: { type: "number", description: "Shortest pause to report (default 0.6)." } } } },
  { name: "cutgenie_transcribe", description: "Write down what is said in a clip, with the time of every word, using Whisper on the person's Mac (read only; the file is never changed, nothing is uploaded). It reads files on the Mac directly: give a clip id from cutgenie_get_project (e.g. c1); never ask for the file to be attached, and never transcribe in your own sandbox. Use it to place titles, lower thirds, zooms or cuts by what the person says instead of asking for timestamps. Returns source-file times; convert them to timeline times.",
    inputSchema: { type: "object", properties: {
      clip: { type: "string", description: "A clip id from cutgenie_get_project, e.g. \"c1\". Transcribes only the part of the file that clip uses." },
      path: { type: "string", description: "Or a media file on this Mac." },
      language: { type: "string", description: "Spoken language code, e.g. \"en\" or \"hi\" (default: detect)." },
      from: { type: "number", description: "Only transcribe from this source time (seconds)." },
      to: { type: "number", description: "Only transcribe up to this source time (seconds)." },
      model: { type: "string", enum: ["base", "small", "large"], description: "Speech model. Default: the largest one on this Mac. base 150 MB (fast, clear English only), small 490 MB, large 1.6 GB (best; use it for Hindi, Hinglish and other non-English speech)." },
      download_model: { type: "boolean", description: "Download the chosen model if it is missing (once, from huggingface.co). Only true after the person chose a model and said yes to its size." } } } },
  { name: "cutgenie_export", description: "Export the project to a file. Refuses to replace an existing file unless replace_existing is true, which you may only set after the person said yes to replacing that exact file.",
    inputSchema: { type: "object", required: ["out"], properties: {
      out: { type: "string", description: "Output file, e.g. ~/Movies/My video.mp4 (.mp4, .mov, .wav, .m4a)." },
      preset: { type: "string", enum: ["youtube", "compatible", "small", "master", "audio"], description: "youtube = HEVC 12 Mbps; compatible = H.264 20 Mbps; small = HEVC 6 Mbps 1080p; master = ProRes 422 .mov; audio = WAV." },
      from: { type: "number", description: "Start time, to export only a part." },
      to: { type: "number", description: "End time." },
      replace_existing: { type: "boolean", description: "Only true after the person agreed to replace the existing file." } } } },
];

const text = (s) => ({ content: [{ type: "text", text: typeof s === "string" ? s : JSON.stringify(s, null, 1) }] });
const fail = (s) => ({ content: [{ type: "text", text: s }], isError: true });
const reply = (r) => (r && r.ok === false ? fail(r.error || "Cutgenie refused the command.") : text(r));

function summary(p) {
  const name = (id) => { const a = (p.assets || []).find((x) => x.id === id); return a ? path.basename(a.path) : id; };
  const filePath = (id) => { const a = (p.assets || []).find((x) => x.id === id); return a ? a.path : ""; };
  const r = (x) => Math.round(x * 1000) / 1000;
  return {
    name: p.name, settings: p.settings,
    main_track: (p.clips || []).map((c) => ({ id: c.id, file: name(c.asset), path: filePath(c.asset), offset: r(c.offset || 0), duration: r(c.duration), sourceIn: r(c.sourceIn || 0), speed: c.speed, disabled: c.disabled })),
    upper_tracks: (p.upperClips || []).map((c) => ({ id: c.id, file: name(c.asset), lane: c.lane, offset: r(c.offset || 0), duration: r(c.duration) })),
    graphics: (p.overlays || []).map((o) => ({ id: o.id, name: o.name, lane: o.lane, offset: r(o.offset), duration: r(o.duration) })),
    sound_clips: (p.audioClips || []).map((a) => ({ id: a.id, offset: r(a.offset || 0), duration: r(a.duration) })),
    markers: (p.markers || []).map((m) => ({ id: m.id, name: m.name, time: r(m.time) })),
  };
}

function findFfmpeg() {
  for (const d of [...(process.env.PATH || "").split(":"), "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]) {
    const f = path.join(d, "ffmpeg"); if (d && fs.existsSync(f)) return f;
  }
  return null;
}

function findBin(name) {
  for (const d of [...(process.env.PATH || "").split(":"), "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]) {
    const f = path.join(d, name); if (d && fs.existsSync(f)) return f;
  }
  return null;
}

// Whisper speech models, kept in ~/Library/Application Support/Cutgenie/whisper/ (or CUTGENIE_WHISPER_MODEL for one file).
const MODELS = {
  base: { file: "ggml-base.bin", size: "150 MB", good: "fast; good for clear English, weak for Hindi and mixed Hindi-English" },
  small: { file: "ggml-small.bin", size: "490 MB", good: "better English and other languages; still weak for Hinglish" },
  large: { file: "ggml-large-v3-turbo.bin", size: "1.6 GB", good: "best: Hindi, Hinglish and most other languages, accents, music in the background; about 3 to 5 times slower than base" },
};
const MODEL_DIR = path.join(os.homedir(), "Library/Application Support/Cutgenie/whisper");
const modelFile = (k) => path.join(MODEL_DIR, MODELS[k].file);
const installedModels = () => Object.keys(MODELS).filter((k) => fs.existsSync(modelFile(k)));
const CHOICES = Object.entries(MODELS).map(([k, m]) => `${k} (${m.size}: ${m.good})`).join("; ");

function download(url, dest, hops = 0) {
  const https = require("https");
  return new Promise((resolve, reject) => https.get(url, { headers: { "User-Agent": "cutgenie" } }, (res) => {
    if (res.statusCode >= 300 && res.statusCode < 400 && res.headers.location && hops < 5) {
      res.resume(); return resolve(download(new URL(res.headers.location, url).href, dest, hops + 1));
    }
    if (res.statusCode !== 200) { res.resume(); return reject(new Error("HTTP " + res.statusCode)); }
    fs.mkdirSync(path.dirname(dest), { recursive: true });
    const part = dest + ".part", out = fs.createWriteStream(part);
    res.pipe(out); out.on("finish", () => out.close(() => {
      if (fs.statSync(part).size < 1e6) return reject(new Error("download too small"));
      fs.renameSync(part, dest); resolve();
    }));
    out.on("error", reject); res.on("error", reject);
  }).on("error", reject));
}

const run = (bin, args) => new Promise((resolve) => execFile(bin, args, { maxBuffer: 256 * 1024 * 1024 }, (err, o, e) => resolve({ err, out: String(o), errText: String(e) })));

async function transcribe(a) {
  const ff = findFfmpeg();
  if (!ff) return fail("ffmpeg is not installed. Ask the person before installing it (for example with Homebrew: brew install ffmpeg).");
  const wc = findBin("whisper-cli");
  if (!wc) return fail("Whisper (whisper-cli) is not installed. Ask the person before installing it. It is free and runs on this Mac: in Terminal, brew install whisper-cpp. Then try again.");
  if (a.clip) {
    const r = await cutgenie("get_project");
    if (!r.ok) return reply(r);
    const p = r.project || r, all = [...(p.clips || []), ...(p.upperClips || []), ...(p.audioClips || [])];
    const c = all.find((x) => x.id === a.clip); if (!c) return fail(`No clip "${a.clip}" in the open project.`);
    const asset = (p.assets || []).find((x) => x.id === c.asset); if (!asset) return fail(`Clip "${a.clip}" has no media file.`);
    a = { ...a, path: asset.path };
    const si = c.sourceIn || 0, len = (c.duration || 0) * (c.speed || 1);
    if (a.from === undefined) a.from = si;
    if (a.to === undefined && len > 0) a.to = si + len;
  }
  if (!a.path) return fail("Give clip (an id from cutgenie_get_project) or path.");
  const file = String(a.path || "").replace(/^~(?=\/|$)/, os.homedir());
  if (!fs.existsSync(file)) return fail("File not found on this Mac: " + file);
  let key = a.model && MODELS[a.model] ? a.model : null, model;
  if (process.env.CUTGENIE_WHISPER_MODEL && !key) { model = process.env.CUTGENIE_WHISPER_MODEL; key = "custom"; }
  else {
    const have = installedModels();
    if (!key) key = have[have.length - 1];
    if (!key)
      return fail(`No Whisper speech model is on this Mac yet (model is not downloaded). Before downloading, tell the person the choices in plain words and let them pick: ${CHOICES}. For Hindi, Hinglish or another language than English, recommend large. Each is downloaded once from huggingface.co. Then call cutgenie_transcribe again with model and download_model: true.`);
    model = modelFile(key);
    if (!fs.existsSync(model)) {
      if (a.download_model !== true)
        return fail(`The "${key}" speech model (${MODELS[key].size}) is not on this Mac yet (model is not downloaded). Ask the person whether to download it (once, from huggingface.co; it may take a few minutes). If they say yes, call cutgenie_transcribe again with model: "${key}" and download_model: true.`);
      try { await download("https://huggingface.co/ggerganov/whisper.cpp/resolve/main/" + MODELS[key].file, model); }
      catch (e) { return fail("Could not download the speech model: " + e.message); }
    }
  }
  const from = Math.max(0, Number(a.from) || 0), to = a.to !== undefined ? Number(a.to) : null;
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "cutgenie-whisper-"));
  try {
    const wav = path.join(tmp, "audio.wav");
    const cut = [...(from ? ["-ss", String(from)] : []), ...(to !== null ? ["-to", String(to)] : [])];
    const x = await run(ff, ["-v", "error", "-nostdin", "-y", "-i", file, ...cut, "-vn", "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", wav]);
    if (x.err || !fs.existsSync(wav)) return fail("ffmpeg could not read the sound in the file.");
    const lang = String(a.language || "auto").replace(/[^a-z-]/gi, "") || "auto";
    const w = await run(wc, ["-m", model, "-f", wav, "-l", lang, "-ojf", "-of", path.join(tmp, "out"), "-np", "-t", String(Math.min(8, os.cpus().length))]);
    let j; try { j = JSON.parse(fs.readFileSync(path.join(tmp, "out.json"), "utf8")); }
    catch { return fail("Whisper could not transcribe the file. " + w.errText.split("\n").filter(Boolean).slice(-3).join(" ")); }
    const r = (ms) => Math.round((from + ms / 1000) * 100) / 100;
    const segments = [], words = [];
    for (const s of j.transcription || []) {
      const t = (s.text || "").trim(); if (!t) continue;
      segments.push({ start: r(s.offsets.from), end: r(s.offsets.to), text: t });
      for (const k of s.tokens || []) {
        const kt = k.text || ""; if (!kt || /^\[_|^\[[A-Z_]+\]$|^<\|/.test(kt)) continue;
        const last = words[words.length - 1];
        if (!last || /^\s/.test(kt) || last.seg !== segments.length) words.push({ word: kt.trim(), start: r(k.offsets.from), end: r(k.offsets.to), seg: segments.length });
        else { last.word += kt; last.end = r(k.offsets.to); }
      }
    }
    const spoken = (j.result && j.result.language) || lang;
    const out = words.filter((x) => x.word);
    let tip;
    if (key !== "large" && key !== "custom") {
      const bad = out.length > 20 && new Set(out.map((x) => x.word.toLowerCase())).size < out.length / 6;
      if (spoken !== "en" || bad) tip = `This used the "${key}" model, which often gets ${spoken === "en" ? "this speech" : "Hindi, Hinglish and other non-English speech"} wrong (repeated junk, or an English translation instead of the words as spoken). Tell the person, and offer the large model: ${MODELS.large.size}, downloaded once, much better for Hindi and mixed Hindi-English. With a yes, call again with model: "large" and download_model: true. For Hinglish captions, language "hi" writes Hindi in Devanagari.`;
    }
    return text(JSON.stringify({ file, model: key, language: spoken, ...(tip ? { tip } : {}),
      words: out.map(({ seg, ...x }) => x), segments,
      note: "Source-file times in seconds. timeline = clip offset + (source − sourceIn); skip words outside the clip's sourceIn … sourceIn + duration. Word times can be off by about 0.2 s, so start graphics a moment early." }));
  } finally { fs.rmSync(tmp, { recursive: true, force: true }); }
}

async function call(name, a = {}) {
  switch (name) {
    case "cutgenie_status": return reply(await cutgenie("status"));
    case "cutgenie_get_project": {
      const r = await cutgenie("get_project");
      if (!r.ok) return reply(r);
      const p = r.project || r; return text(a.full ? p : summary(p));
    }
    case "cutgenie_undo": return reply(await cutgenie("undo"));
    case "cutgenie_redo": return reply(await cutgenie("redo"));
    case "cutgenie_save": { const r = await cutgenie("save"); if (r.ok) savedThisSession = true; return reply(r); }
    case "cutgenie_render_frame": {
      const out = path.join(os.tmpdir(), `cutgenie-frame-${process.pid}-${Date.now()}.png`);
      const r = await cutgenie("render_frame", { time: a.time, out });
      if (!r.ok) return reply(r);
      try { const data = fs.readFileSync(out).toString("base64"); fs.unlinkSync(out);
        return { content: [{ type: "image", data, mimeType: "image/png" }, { type: "text", text: `Frame at ${a.time} s` }] };
      } catch (e) { return fail("Rendered, but could not read the picture: " + e.message); }
    }
    case "cutgenie_find_silences": {
      const ff = findFfmpeg();
      if (!ff) return fail("ffmpeg is not installed. Ask the person before installing it (for example with Homebrew: brew install ffmpeg).");
      const file = String(a.path || "").replace(/^~(?=\/|$)/, os.homedir());
      if (!fs.existsSync(file)) return fail("File not found: " + file);
      const noise = Number(a.noise_db ?? -35), min = Number(a.min_seconds ?? 0.6);
      return await new Promise((resolve) => execFile(ff, ["-hide_banner", "-nostats", "-i", file, "-af", `silencedetect=noise=${noise}dB:d=${min}`, "-f", "null", "-"],
        { maxBuffer: 64 * 1024 * 1024 }, (err, _o, se) => {
          const pauses = []; let start = null;
          for (const l of String(se).split("\n")) {
            const s = l.match(/silence_start: (-?[\d.]+)/); if (s) start = Math.max(0, Number(s[1]));
            const e = l.match(/silence_end: ([\d.]+)/); if (e && start !== null) { pauses.push({ start, end: Number(e[1]) }); start = null; }
          }
          if (err && !pauses.length && !/silence/.test(String(se))) return resolve(fail("ffmpeg could not read the file."));
          resolve(text({ file, pauses, note: "Source-file times. timeline = clip offset + (source − sourceIn). Cut from the end backwards." }));
        }));
    }
    case "cutgenie_transcribe": return await transcribe(a);
    case "cutgenie_export": {
      if (!a.out) return fail("Give out, the file to write.");
      const out = String(a.out).replace(/^~(?=\/|$)/, os.homedir());
      if (exists(out) && a.replace_existing !== true)
        return fail(`"${out}" already exists. Ask the person whether to replace it, or choose a new name (for example add "v2").`);
      const presets = { youtube: { codec: "hevc", mbps: 12, audio: "aac", kbps: 320 }, compatible: { codec: "h264", mbps: 20 },
        small: { codec: "hevc", mbps: 6, width: 1920, height: 1080 }, master: { codec: "prores422", audio: "pcm" }, audio: {} };
      const args = { out, ...(presets[a.preset || "youtube"] || {}) };
      if (a.from !== undefined) args.from = a.from; if (a.to !== undefined) args.to = a.to;
      if (exists(out) && a.replace_existing === true) args.overwrite = true;
      const r = await cutgenie("export", args);
      if (!r.ok) return reply(r);
      let size = ""; try { size = ` (${(fs.statSync(out).size / 1e6).toFixed(1)} MB)`; } catch {}
      return text(`Exported ${out}${size}.`);
    }
    case "cutgenie_command": {
      const cmd = String(a.command || "").trim().replace(/-/g, "_");
      const args = a.args && typeof a.args === "object" ? { ...a.args } : {};
      if (!cmd) return fail("Give a command name.");
      if (BLOCKED[cmd]) return fail(BLOCKED[cmd]);
      if (TESTING.test(cmd)) return fail(`"${cmd}" is a testing aid, not an editing command.`);
      if ("overwrite" in args) return fail("Overwriting files isn't allowed through this tool.");
      if (cmd === "import_fcpxml" && args.out && exists(String(args.out))) return fail(`"${args.out}" already exists; choose a new project file name.`);
      if (cmd === "new_project" && args.path && exists(String(args.path))) return fail(`"${args.path}" already exists; open it instead, or choose a new name.`);
      if (!READ_ONLY.has(cmd) && !["new_project", "open", "save", "undo", "redo"].includes(cmd)) {
        const problem = await saveFirst(); if (problem) return fail(problem);
      }
      const r = await cutgenie(cmd, args);
      if (r.ok && ["save", "new_project", "open"].includes(cmd)) savedThisSession = cmd === "save" ? true : false;
      return reply(r);
    }
    default: return fail("Unknown tool " + name);
  }
}

// ---------- MCP over stdio (newline-delimited JSON-RPC 2.0) ----------
const send = (m) => process.stdout.write(JSON.stringify(m) + "\n");
async function handle(m) {
  const { id, method, params } = m;
  if (id === undefined || id === null) return; // notifications (initialized, cancelled) need no answer
  try {
    if (method === "initialize")
      return send({ jsonrpc: "2.0", id, result: { protocolVersion: (params && params.protocolVersion) || "2025-06-18",
        capabilities: { tools: {} }, serverInfo: { name: "cutgenie", version: VERSION }, instructions: RULES + "\n\n" + GUIDE } });
    if (method === "ping") return send({ jsonrpc: "2.0", id, result: {} });
    if (method === "tools/list") return send({ jsonrpc: "2.0", id, result: { tools: TOOLS } });
    if (method === "tools/call") return send({ jsonrpc: "2.0", id, result: await call(params.name, params.arguments || {}) });
    if (method === "prompts/list") return send({ jsonrpc: "2.0", id, result: { prompts: [] } });
    if (method === "resources/list") return send({ jsonrpc: "2.0", id, result: { resources: [] } });
    send({ jsonrpc: "2.0", id, error: { code: -32601, message: "Method not found: " + method } });
  } catch (e) { send({ jsonrpc: "2.0", id, error: { code: -32603, message: String(e && e.message || e) } }); }
}
let buf = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (c) => { buf += c; let i;
  while ((i = buf.indexOf("\n")) >= 0) { const line = buf.slice(0, i).trim(); buf = buf.slice(i + 1);
    if (!line) continue; let m; try { m = JSON.parse(line); } catch { send({ jsonrpc: "2.0", id: null, error: { code: -32700, message: "Parse error" } }); continue; }
    handle(m);
  } });
process.stdin.on("end", () => process.exit(0));
