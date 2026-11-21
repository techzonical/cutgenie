---
name: cutgenie-export
description: Export a Cutgenie project to a video or sound file: YouTube HEVC, small file, H.264, ProRes master, sound only, or just a part. Use when the person asks to export, render, make the final video, or make a short preview file.
---

# Export
| Goal | Command |
|---|---|
| YouTube | `cg export out=<file>.mp4 codec=hevc mbps=12 audio=aac kbps=320` |
| Plays anywhere | `cg export out=<file>.mp4 codec=h264 mbps=20` |
| Small file to send | `cg export out=<file>.mp4 codec=hevc mbps=6 width=1920 height=1080` |
| Master | `cg export out=<file>.mov codec=prores422 audio=pcm` |
| Sound only | `cg export out=<file>.wav` |
| A part | add `from=<t> to=<t>` |

1. Ask where to save it if the person didn't say. Default to the project's folder, never inside a media folder
   unless asked.
2. **If the file already exists, ask before replacing it.** Only then add `overwrite=true`, or pick a new name such
   as `… v2.mp4`.
3. Export can take a while; the command returns when the file is written. Then report the file's path and size
   (`ls -lh`).

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

Person: "Export it for YouTube."

```bash
ls "$HOME/Movies/Laptop review.mp4"          # not there yet
cg export out="$HOME/Movies/Laptop review.mp4" codec=hevc mbps=12 audio=aac kbps=320
ls -lh "$HOME/Movies/Laptop review.mp4"
```

Reply: "Exported *Laptop review.mp4* (412 MB) to your Movies folder."
