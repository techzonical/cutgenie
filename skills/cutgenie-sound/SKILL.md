---
name: cutgenie-sound
description: Fix and balance sound in Cutgenie: clip volume and fades, music, gate, EQ, compressor, limiter and loudness matching (-14 LUFS for YouTube). Use when the person asks to make voice clearer or louder, lower music, add fades, remove hum or hiss, or make the video as loud as others.
---

# Sound: volume, voice and loudness
## Clips

- Volume: `cg set_volume id=<clip> gain_db=-6` (keys="t:db,..." for changes over time).
- Fades: `cg set_fade id=<clip> in=0.5 out=2`.
- Music: `cg add_audio path=<file> at=0` (its own track; returns an id). Duck it under speech with `gain_db=-18`.

## Voice on a whole track

Pick the track first: `cg audio_track track=A1`. Effects run Gate → EQ → Compressor → Output → Limiter.

- Rumble: `cg set_eq band=0 type=highpass freq=80` (band = count adds a band).
- Hum: `cg set_eq band=1 type=notch freq=50` (60 in North America).
- Presence: `cg set_eq band=2 type=bell freq=3000 gain=2 q=1`.
- Background noise between words: `cg set_gate enabled=true threshold=-50 range=-20` (threshold in dB; also
  `attack=` and `release=` in ms).
- Even out loud and quiet words: `cg set_comp enabled=true threshold=-20 ratio=3 makeup=4`.

## Loudness

1. `cg analyze_audio` → integrated LUFS and peak.
2. `cg match_loudness target=-14` (YouTube). Turn the limiter on with `cg set_limiter enabled=true ceiling=-1` so peaks stay under −1 dBFS.
3. `cg analyze_audio` again and report the before and after numbers.

Save settings for next time: `cg save_audio_preset name="My voice"`; reuse with `cg apply_audio_preset name=...`.

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

Person: "My video is too quiet."

```bash
cg save
cg analyze_audio                      # integrated -23.1 LUFS, peak -6.2 dBFS
cg match_loudness target=-14
cg analyze_audio                      # integrated -14.0 LUFS
```

Reply: "It was −23 LUFS, now −14, the level YouTube uses. Peaks are kept under the limiter's ceiling."
