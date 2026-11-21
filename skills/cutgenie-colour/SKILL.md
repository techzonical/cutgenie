---
name: cutgenie-colour
description: Colour-correct and grade clips in Cutgenie: exposure, contrast, saturation, white balance, colour wheels, LUTs and saved looks. Use when the person asks to brighten, fix colour, warm up or cool down a shot, match cameras, apply a LUT, or copy a grade to other clips.
---

# Colour correction and grading
| Task | Command |
|---|---|
| Basic | `cg set_color clip=<id> exposure=0.2 contrast=1.1 saturation=1.05 temperature=0.1 tint=0` |
| Same for every clip from that file | add `same_media_as=<id>` instead of `clip=` |
| Wheels | `cg set_wheels clip=<id> wheel=shadows hue=220 amount=0.1` (global, shadows, midtones, highlights) |
| LUT | `cg set_lut clip=<id> slot=input path=<file.cube>` (log footage) or `slot=creative intensity=0.6` |
| Remove a LUT | `cg remove_lut clip=<id> slot=...` |
| Copy a grade | `cg copy_grade clip=<id>` then `cg paste_grade ids=c3,c4` |
| Save / apply a look | `cg save_look name=... clip=<id>`, `cg apply_look name=... ids=...` |

Neutral values: exposure 0, contrast 1, saturation 1, temperature 0, tint 0. Make small changes (exposure ±0.3,
saturation 0.9–1.2) and check a frame: `cg render_frame time=<t> out=/tmp/frame.png`, then look at the picture.

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

Person: "Clip 4 looks too dark and cold."

```bash
cg save
cg set_color clip=c4 exposure=0.25 temperature=0.12
cg render_frame time=31 out=/tmp/c4.png
```

Reply: "Brightened clip 4 a little and warmed it up. Compare with ⌘Z / ⇧⌘Z."
