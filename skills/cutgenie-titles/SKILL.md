---
name: cutgenie-titles
description: Add and style text, lower thirds, shapes and saved titles in Cutgenie, with animation. Use when the person asks for a title, caption, name tag, lower third, text on screen, a box or shape behind text, or to reuse a saved title.
---

# Titles, text and shapes
## Add

- Text: `cg add_text text="Hello" at=<t> dur=4` → returns the layer id (`g1`…).
- Shape: `cg add_shape kind=rect|circle|line|solid|gradient at=<t> dur=4`.
- Saved title: `cg add_title name="<saved name>" at=<t>`; save one with `cg save_title name=... ids=g1,g2`.

## Style and place

- `cg text_edit id=g1 text="New words" font="Helvetica Neue" size=72 bold=true color=1,1,1,1 stroke_width=4 stroke_color=0,0,0,1`
- Two styles on one line: `cg text_edit id=g1 add_run=" · Product reviewer"` then `cg text_edit id=g1 run=1 size=40`.
  For two lines (name above, job below), use two text layers.
- Position, size, fades: `cg layer_set ids=g1 x=-600 y=-380 scale=1 fade_in=0.3 fade_out=0.3` (px from the centre, y up).
- Effects: `cg layer_fx ids=g1 type=shadow` (also glow, stroke, corners, blur, color, tint).
- Timing: `cg overlay_edit id=g1 offset=<t> duration=<s>`.

Keep text inside the frame's safe area (about 5 % from the edges) and readable: big enough, with an outline or a
shape behind it on busy footage.

## Talking to Cutgenie

Cutgenie must be open. It listens on `127.0.0.1:7878` (or the port in `CUTGENIE_PORT`). Send every command with this
helper, defined once per shell:

```bash
cg() {  # cg <command> key=value ...
  if command -v cutgeniectl >/dev/null; then cutgeniectl "$@"; return; fi
  local c=$1; shift; local j="{\"cmd\":\"$c\""
  for a in "$@"; do j="$j,\"${a%%=*}\":\"${a#*=}\""; done
  curl -s -X POST "http://127.0.0.1:${CUTGENIE_PORT:-7878}/command" -d "$j}"; echo
}
```

Every reply is JSON with `"ok": true` or `"ok": false` and an `"error"`. Times are seconds on the timeline. If the
reply says it can't connect, ask the person to open Cutgenie. Run `cg get_project` to see clip ids (`c1`, `c2`…), their
`offset` (start on the timeline), `sourceIn` and `duration`; graphics are in `overlays` (`g1`…), sound-only clips in
`audioClips`.

## Safety rules (always)

1. **Never touch original media.** Never move, rename, re-encode, overwrite or delete the person's video, sound or
   image files. Cutgenie only stores edits in the project file; keep it that way. Temporary files go in `/tmp`.
2. **Save a version first.** Before the first change, run `cg save`. Cutgenie keeps the replaced file as a version
   (the last 10), so the person can go back with **Versions…**. If the project has no file yet, ask where to save it.
3. **Undo on mistakes.** If a command did something unexpected, run `cg undo` (once per step) and check with
   `cg get_project` before trying again. Never "fix forward" with more edits on top of a wrong one.
4. **Ask before overwriting exports.** Never pass `overwrite=true` unless the person said yes to replacing that exact
   file. Never delete files.
5. **Say what you will do, then do it in small steps**, checking `get_project` after each group of edits. Tell the
   person in plain words what changed and how to undo it (⌘Z, or Versions…).

## Example

Person: "Add a lower third at 0:05 with my name, Sam, and 'Tech reviewer' under it."

```bash
cg save
cg add_shape kind=rect at=5 dur=5                      # g1: the box behind the text
cg layer_set ids=g1 x=-560 y=-380 fade_in=0.3 fade_out=0.3
cg add_text text="Sam" at=5 dur=5 size=64              # g2: the name
cg layer_set ids=g2 x=-560 y=-345 fade_in=0.3 fade_out=0.3
cg add_text text="Tech reviewer" at=5 dur=5 size=36    # g3: the job
cg text_edit id=g3 bold=false
cg layer_set ids=g3 x=-560 y=-415 fade_in=0.3 fade_out=0.3
cg render_frame time=6 out=/tmp/lower-third.png        # look at it before telling the person
```

Reply: "Added a lower third from 0:05 to 0:10. Select it and use the Effects tab to change its look."
