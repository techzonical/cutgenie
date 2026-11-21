# Changelog

## Unreleased

- Documentation: 13 chapters for beginners in `docs/`, with screenshots made by `scripts/make_screenshots.sh`.
- Claude Code skills (`skills/`) and plugin (`.claude-plugin/`) for editing by asking Claude.
- Cutgenie extension for the Claude desktop app (`mcp/`, packed by `scripts/make_mcpb.sh`): an MCP server with no
  dependencies that saves a version before editing and never replaces an export without a yes.
- New control command `set_zoom` (main-track zoom keyframes); testing aids `ui_size`, `ui_sections`, `ui_split`.
- Fix: `seek` now moves the playhead as well as the picture.

## 0.1.0 (first public release)

- Timeline editing: magnetic main track, multiple video / graphics / sound tracks, blade, trim, roll, slip, slide,
  groups, markers, snapping, sync by sound.
- Clip transforms with keyframes, easing presets and a bezier graph editor; on-screen handles.
- Colour: primary controls, colour wheels, LUTs, HLG / log handling, saved looks.
- Graphics: text, shapes, blur / pixelate areas, builds, behaviours, masks, effects, saved titles.
- Sound: volume keyframes, fades, EQ, compressor, gate, limiter, loudness measuring.
- Project management: project browser, versions, relink and collect media, autosave and crash recovery.
- Export presets including constant-quality "Smart size" HEVC; background export.
- Final Cut Pro XML import.
- Local control interface (`cutgeniectl`) with about 150 commands.
