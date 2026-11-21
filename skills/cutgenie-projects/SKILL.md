---
name: cutgenie-projects
description: Create, open, save, duplicate and restore Cutgenie projects, make a vertical (9:16) copy, relink missing media and restore earlier versions. Use when the person asks to start a new video project, save, make a Shorts/Reels version, go back to an earlier version, or fix missing (offline) clips.
---

# Projects, versions and missing media
## What you can do

| Task | Command |
|---|---|
| New project | `cg new_project path=<folder>/<name>.cutgenie.json width=1920 height=1080 fps=30` |
| Open | `cg open path=<file>` |
| Save | `cg save` (Save As: `cg save path=<new file>`) |
| Duplicate | `cg duplicate_project path=<new file>` |
| Vertical copy for Shorts / Reels | `cg duplicate_project path=<new file> vertical=true` |
| Change size / frame rate | `cg project_settings width= height= fps= fit=fit` |
| Restore an earlier version | `cg restore_version file=<version file>` (one undo step; nothing is saved until `cg save`) |
| Missing media | `cg relink_folder dir=<folder where the files are now>` |

Versions live in Cutgenie's own folder; open **Versions…** in the app to see them, or ask the person to pick one.
`relink_folder` only re-points the project at files with the same name; it never copies or moves media.

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

Person: "Make a vertical copy for YouTube Shorts."

```bash
cg save
cg duplicate_project path="$HOME/Movies/Laptop review (vertical).cutgenie.json" vertical=true
```

Reply: "Done: *Laptop review (vertical)* is a 9:16 copy with every clip filling the frame. Your original project is
unchanged."
