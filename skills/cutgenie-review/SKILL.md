---
name: cutgenie-review
description: Review a Cutgenie edit and report problems before export: gaps, very short clips, disabled clips, missing media, loud or quiet sound, clipped peaks, and long silences. Use when the person asks to check the edit, review it, or asks if it is ready to export.
---

# Review the edit
This skill only **reads**. Don't change anything unless the person asks after seeing the report.

1. `cg get_project` and check:
   - Gaps between V1 clips (one clip's `offset + duration` < the next clip's `offset`).
   - Very short clips (under 0.3 s), often leftovers from cutting.
   - Clips switched off (`disabled: true`).
   - Graphics that run past the end of the video.
2. Missing media: check every asset `path` exists (`test -f`).
3. Sound: `cg analyze_audio` → integrated loudness (aim for about −14 LUFS) and peak (should stay below −1 dBFS).
4. Look at a few frames: `cg render_frame time=<t> out=/tmp/review-<n>.png` at the start, around each title, and at
   the end.
5. Report a short list: each problem with its time (m:ss), and the fix you suggest. Offer to fix them with the other
   Cutgenie skills.

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

Person: "Is it ready to export?"

Reply after checking: "Almost. I found 3 things:
1. A 0.1 s leftover clip at 2:14 (probably from a cut). Remove it?
2. A small gap at 5:02 that will show black.
3. Loudness is −19 LUFS; YouTube plays videos at about −14. Raise it?
Everything else looks fine."
