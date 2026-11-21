---
name: cutgenie-setup
description: Check that Cutgenie is running and can be controlled, find or build cutgeniectl, and open or create a project. Use first, or whenever the person says Claude can't reach Cutgenie, or asks how to start editing with Claude.
---

# Set up Cutgenie for editing with Claude
Use this before the other Cutgenie skills, or when a command can't reach the app.

## Steps

1. Define the `cg` helper below and run `cg status`.
   - `"ok": true` → Cutgenie is ready. Tell the person which project is open (`project`, `path`).
   - "cannot reach" / connection refused → ask the person to open Cutgenie, then try again.
2. `cutgeniectl` is optional. The helper falls back to `curl`, which every Mac has. If the person has the source code,
   `zsh scripts/build_app.sh` builds `build/cutgeniectl`; only build it if they ask, and ask before installing anything.
3. Open a project: `cg open path=~/Movies/My video.cutgenie.json`. To start a new one, ask for a name and folder, then
   `cg new_project path=<folder>/<name>.cutgenie.json width=1920 height=1080 fps=30` (use the camera's size and
   frame rate if known; `cg match_clip path=<first clip>` sets them from a clip).
4. Run `cg get_project` and summarise in one or two sentences what is on the timeline.

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

Person: "Can you see my Cutgenie?"

```bash
cg status
# {"ok":true,"project":"Laptop review","path":"/Users/me/Movies/Laptop review.cutgenie.json","clips":14,...}
```

Reply: "Yes. *Laptop review* is open, with 14 clips (about 12 minutes). What would you like to do?"
