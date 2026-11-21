---
name: cutgenie-trim
description: Trim, split, move, roll, slip and reorder clips in Cutgenie. Use when the person asks to shorten a clip, cut at a time, remove the start or end of a clip, move a clip, or tighten an edit.
---

# Trim, split and move clips
| Task | Command |
|---|---|
| Split at a time | `cg split at=<t>` (selected clip) or `cg blade_all at=<t>` (every track) |
| Trim the start or end | `cg trim clip=<id> edge=start to=<timeline time>` (or `edge=end`) |
| Trim by dragging an amount | `cg drag_edit clip=<id> mode=trim_end delta=-1.5` |
| Move the cut between two clips | `cg roll at=<edit time> delta=<s>` (total length stays the same) |
| Show a different part of the media | `cg slip clip=<id> delta=<s>` |
| Move a clip between its neighbours | `cg slide clip=<id> delta=<s>` |
| Move clips | `cg move_items ids=c4,c5 delta=<s>` |
| Nudge by frames | select it, then `cg nudge frames=-2` (graphics and V2+ clips; on V1 use trim or roll) |
| Move to a track above (B-roll) | `cg to_lane clip=<id> lane=1 at=<t>` |
| Remove and close the gap | `cg ripple_delete clip=<id>` |
| Speed | `cg set_speed clip=<id> speed=1.25` |

Find ids and times with `cg get_project`. Check the result after each change; trims can affect clips after it on the
magnetic main track.

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

Person: "Take the last 2 seconds off clip 3."

```bash
cg save
cg get_project                 # c3: offset 20, duration 9 → ends at 29
cg trim clip=c3 edge=end to=27
```

Reply: "Clip 3 now ends 2 seconds earlier, and the clips after it moved up. ⌘Z to undo."
