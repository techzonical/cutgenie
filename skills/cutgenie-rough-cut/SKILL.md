---
name: cutgenie-rough-cut
description: Make a rough cut in Cutgenie: add clips in order, find silent pauses with ffmpeg and remove them, cut out takes the person marks, and tidy gaps. Use when the person asks to remove silences, dead air or pauses, cut a talking-head video down, or put clips on the timeline in order.
---

# Rough cut: clips in order, silences out
## Put clips on the timeline

`cg add_clip path=<file>` appends a clip at the end (magnetic V1). Add files in the order the person wants. Use
`cg lib_add path=<folder>` to show a folder in the media panel without adding it to the timeline.

## Remove silent pauses

1. `cg save`.
2. For each V1 clip from `cg get_project`, find silences in its **source file** with ffmpeg (read-only):
   ```bash
   ffmpeg -hide_banner -nostats -i "<file>" -af silencedetect=noise=-35dB:d=0.6 -f null - 2>&1 | grep silence_
   ```
   If `ffmpeg` is missing, ask before installing it (for example `brew install ffmpeg`).
3. Turn source times into timeline times: `timeline = clip.offset + (source − clip.sourceIn)`, keeping only silences
   inside `sourceIn … sourceIn + duration`. Leave about 0.15 s of pause on each side so speech isn't clipped.
4. Remove them **from the end of the timeline backwards**, so earlier times don't shift:
   `cg ripple_delete from=<start> to=<end>`.
5. Run `cg get_project` and tell the person how many pauses were removed and how much shorter the video is.

Suggest playing it back. One `cg undo` removes one cut; `restore_version` returns to the version saved in step 1.

## Other cuts

- Remove a stretch the person describes: `cg ripple_delete from= to=`.
- Cut at a time: `cg blade_all at=<t>`.
- Leave a gap instead of closing it: `cg delete clip=<id>`.

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

Person: "Cut the pauses out of my intro."

```bash
cg save
cg get_project            # c1 = intro.mp4, offset 0, sourceIn 0, duration 48
ffmpeg -hide_banner -nostats -i ~/Movies/intro.mp4 -af silencedetect=noise=-35dB:d=0.6 -f null - 2>&1 | grep silence_
# silence_start: 12.4 / silence_end: 14.1 ... silence_start: 30.2 / silence_end: 31.5
cg ripple_delete from=30.35 to=31.35
cg ripple_delete from=12.55 to=13.95
```

Reply: "I removed 2 pauses (2.4 s). Press Space to watch; ⌘Z puts a cut back."
