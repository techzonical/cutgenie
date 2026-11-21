#!/usr/bin/env python3
"""Rebuilds the command tables in docs/13-reference/06-control-commands.mdx from Editor.handle.

The notes are the `//` comment lines right under each `case "name":` in Sources/CutgenieCore/Editor.swift.
Run it after adding or changing a control command:  python3 scripts/make_control_doc.py
"""
import re, pathlib
root = pathlib.Path(__file__).resolve().parent.parent
src = (root / "Sources/CutgenieCore/Editor.swift").read_text()
body = src[src.index("public func handle("):]
lines = body.split("\n")
cmds = {}
for i, l in enumerate(lines):
    m = re.match(r'\s*case ((?:"[a-z_0-9]+"(?:,\s*)?)+):\s*(?://\s*(.*))?$', l)
    if not m:
        continue
    names = re.findall(r'"([a-z_0-9]+)"', m.group(1))
    notes = [m.group(2)] if m.group(2) else []
    j = i + 1
    while j < len(lines) and lines[j].strip().startswith("//"):
        notes.append(lines[j].strip()[2:].strip()); j += 1
    note = " ".join(n for n in notes if n)
    for n in names:
        if n in ("position", "scale", "opacity", "rotation", "global", "shadows", "midtones", "highlights"):
            continue  # inner switch values, not commands
        if n not in cmds or (note and not cmds[n]):
            cmds[n] = note
def esc(s):  # MDX: no raw < > { } outside code
    return s.replace("|", "/").replace("<", "&lt;").replace(">", "&gt;").replace("{", "&#123;").replace("}", "&#125;")
testing = {n for n, d in cmds.items() if n.startswith("ui_") or "testing aid" in d.lower() or "testing aid" in d}
testing |= {"audio_debug", "convert_probe", "fx_stats", "inspector_tab", "live_bench", "mix_check", "pointer_png",
            "probe_player", "snapshot_ui", "segments", "skim", "scroll_by", "magnetic_drop_x", "set_display"}
def table(names):
    rows = ["| Command | Notes |", "|---|---|"]
    rows += [f"| `{n}` | {esc(cmds[n])} |" for n in sorted(names)]
    return "\n".join(rows)
out = root / "docs/13-reference/06-control-commands.mdx"
text = out.read_text()
start, end = "[//]: # (commands:start)", "[//]: # (commands:end)"
gen = (f"{start}\n\n## Commands\n\n{table(set(cmds) - testing)}\n\n## Testing aids\n\n"
       f"Used by the test suites and the screenshot script to drive and inspect the interface; not needed for editing.\n\n"
       f"{table(testing & set(cmds))}\n\n{end}")
text = text[:text.index(start)] + gen + text[text.index(end) + len(end):]
out.write_text(text)
print(f"{len(cmds)} commands ({len(testing & set(cmds))} testing aids) -> {out.relative_to(root)}")
