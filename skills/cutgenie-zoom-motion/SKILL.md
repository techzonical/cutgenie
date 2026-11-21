---
name: cutgenie-zoom-motion
description: Add zooms, push-ins, punch-ins, picture-in-picture and slide-aside moves with keyframes in Cutgenie. Use when the person asks to zoom in on a moment, add movement to a talking head, make a face cam, or place one video over another.
---

# Zooms and motion
## Zoom on the main track (V1)

`cg set_zoom clip=<id> keys="t:scale[:ease],..." [anchor=x,y]`

- `t` is seconds **from the clip's start**, `scale` 1 = normal, 1.15 = 15 % closer.
- `ease`: `linear`, `in`, `out` or `s` (smooth start and stop).
- `anchor` is the point that stays still (Final Cut units from the centre, y up), e.g. the speaker's face.
- `keys=""` removes the zoom.

Patterns: slow push-in `0:1,6:1.1:s`; punch-in at a key word `3.9:1,4:1.2` (hold it, then back with `7:1.2,7.1:1`).

## Picture in picture (V2 and up)

1. Put the clip on a track above: `cg to_lane clip=<id> lane=1 at=<t>`.
2. Place it: `cg pip clip=<id> x=560 y=300 scale=0.35` (px from the centre, y up). Add `crop=l,r,t,b` to crop.

Tidy busy keyframes with `cg simplify_keys ids=<id>`.

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

Person: "Slowly zoom in on clip 2."

```bash
cg save
cg get_project                         # c2: duration 8
cg set_zoom clip=c2 keys="0:1,8:1.1:s"
```

Reply: "Clip 2 now zooms in gently (10 %) over its 8 seconds. Remove it with ⌘Z."
