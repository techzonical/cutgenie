---
name: cutgenie-blur
description: Hide faces, number plates, screens or private text in Cutgenie with a blur or pixelate area that can follow movement. Use when the person asks to blur, pixelate, censor or hide something in the video.
---

# Blur or pixelate something
1. `cg save`.
2. Add the area at the start time: `cg add_shape kind=blur at=<t> dur=<seconds>` → layer id (`g…`).
3. Place and size it over the thing (px from the centre, y up): `cg layer_set ids=<id> x=<x> y=<y> scale=1`.
   The default box is 500 × 140 px; change it in the app's **Shape** section if needed.
4. If it moves, add positions over time with `at=`: `cg layer_set ids=<id> at=<t> x= y=` at several times.
5. Check frames with `cg render_frame time=<t> out=/tmp/blur.png` at the start, middle and end, and look at each
   picture. Tell the person to play the part back, because a blur that slips even for one frame shows what was hidden.

Pixelate instead of blur, round instead of square, strength and soft edge are in the inspector's **Shape** section.

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

Person: "Blur my phone number on screen from 1:12 to 1:20; it's in the bottom-left."

```bash
cg save
cg add_shape kind=blur at=72 dur=8           # g5
cg layer_set ids=g5 x=-620 y=-400
cg render_frame time=72.5 out=/tmp/b1.png
cg render_frame time=79.5 out=/tmp/b2.png
```

Reply: "Blurred the bottom-left from 1:12 to 1:20. Please watch that part to check nothing shows."
