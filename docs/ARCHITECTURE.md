# Architecture

Cutzonical is one Swift package with three targets.

| Target | What it is |
|---|---|
| `CutzonicalCore` | The engine. Project model, every editing command, undo, rendering, colour, sound, export, safety (autosave, versions, recovery). No SwiftUI. |
| `Cutzonical` | The macOS app: windows, timeline, viewer, inspectors, menus. It calls into `Editor` for every change. |
| `cutzonicalctl` | A tiny command-line client for the control server. |

## The editor (`CutzonicalCore/Editor.swift`)

`Editor` is an `ObservableObject` that owns the open `Project`, the AVFoundation player and the undo stack.
**Every change goes through `Editor.handle(_ command: [String: Any])`**, whether it comes from a menu, a drag in the
timeline, or the control server. That keeps mouse and script edits identical and makes everything testable from outside.

- `mutate { project in ... }` applies a change, validates the timeline (no overlaps on V1, no clips shorter than a frame)
  and rebuilds what playback needs.
- *Live* edits (dragging a slider or a handle) change a copy (`liveLayers`, `liveUpper`, `liveZoom`, `liveMotion`) that
  the renderer reads every frame; `commitLive()` turns the whole drag into one undo step.

## Rendering (`Renderer.swift`, `Compositor.swift`)

- The timeline becomes an `AVMutableComposition`: V1 clips on one video track (gaps filled with black), clips on V2+ on
  their own tracks, sound on A1 (one composition track per audio format, since mixing formats on one tapped track froze
  AVFoundation) and on A2+.
- A custom `AVVideoCompositing` compositor draws each frame with Core Image: colour pipeline and LUTs, zoom and slide on
  V1, picture-in-picture transforms, then graphics layers (text, shapes, images, blur areas) and adjustment layers.
- Colour kernels are Metal Core Image kernels in `Shaders/ColorKernels.ci.metal`, compiled by `scripts/build_app.sh`.
- Frames are always timed to the project's frame grid (variable-frame-rate phone footage otherwise blinked at cuts).
- Export reads the same composition with `AVAssetReader` and writes with `AVAssetWriter` (H.264, HEVC, ProRes, AAC / PCM).
  "Smart size" uses `AVVideoQualityKey` (constant quality) instead of a fixed bitrate.

## Sound (`AudioEngine.swift`, `AudioModel.swift`)

An `MTAudioProcessingTap` per audio track runs the effect chain (EQ, compressor, gate, limiter) and the level meters.
Clip volume and keyframes are mix parameters.

## Safety (`Safety.swift`)

- Saves are atomic; the file being replaced is kept as one of the last 10 versions in
  `~/Library/Application Support/Cutzonical/Versions`.
- Unsaved work is written every minute (and on quit) to `.../Cutzonical/Recovery` and offered back on the next open.
- Problems go to `~/Library/Logs/Cutzonical/cutzonical.log`.

## Control server (`ControlServer.swift`)

A minimal HTTP server on `127.0.0.1` (port 7878, or `CUTZONICAL_PORT`) that accepts `POST /command` with a JSON body
like `{"cmd": "split", "at": 12.5}` and returns `Editor.handle`'s result as JSON. It only listens on the local machine.
