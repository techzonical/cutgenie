# Control commands

While Cutgenie runs it listens on `127.0.0.1:7878` (or `CUTGENIE_PORT`). Send one command with the command-line tool:

```bash
build/cutgeniectl <command> key=value key=value ...
```

or as JSON: `POST http://127.0.0.1:7878/command` with `{"cmd": "<command>", "key": value, ...}`.
Every reply is JSON with `"ok": true|false`, plus `"error"` when something failed. Times are seconds on the timeline.

The notes below come straight from the source (`Sources/CutgenieCore/Editor.swift`, `Editor.handle`), which is the reference.

## Commands

| Command | Notes |
|---|---|
| `add_adjustment` | [at=] [dur=]: an adjustment layer on a track above everything there (default: over the selection, or 10 s from the playhead) |
| `add_audio` | path=<file> [at= default playhead] [lane=] [dur= graphics only, default 5 s]; lane default = first track with room, else a new one |
| `add_clip` | asset=<id> or path=<media file>; optional source_in, dur, offset (default: end of timeline) |
| `add_graphic` | path=<file> [at= default playhead] [lane=] [dur= graphics only, default 5 s]; lane default = first track with room, else a new one |
| `add_lower_third` |  |
| `add_marker` | at= (default: skimmer, else playhead) name= |
| `add_shape` | kind=rect/circle/line/solid/gradient [at= playhead] [dur= 5] [lane=]: a new shape layer, centred in the frame |
| `add_text` | [text=] [at= default playhead] [dur= 5] [lane=] [font=] [size=]: a new text layer, centred in the frame |
| `add_title` | name= [at= playhead]: puts a saved title on the timeline at the playhead, on free tracks |
| `add_track` | kind=audio/graphics : show one more empty track |
| `analyze_audio` | integrated loudness (LUFS, ITU-R BS.1770) and sample peak of the processed sound; optional from= to= seconds |
| `apply_audio_preset` | name= [tracks=A1,A2] (default: the track shown in the Audio panel) |
| `apply_look` | name= [ids=]: gives the selected clips that look |
| `audio_edit` | id= [offset=] [duration=] [trim_start=] [gain_db=] [lane=] |
| `audio_track` | track=A1/A2...: which track the Audio panel edits |
| `autosave_now` |  |
| `blade_all` | cuts every clip and graphic (all lanes) that spans at= (default playhead), selected or not (Final Cut ⇧ blade) |
| `blade_selected` | cuts every selected clip and graphic that spans at= (default playhead); with nothing selected, the clip under the playhead |
| `commit_audio` |  |
| `commit_live` |  |
| `copy` |  |
| `copy_grade` | clip= (default: the clip shown in the Color panel): remembers its whole grade (sliders, wheels, LUTs) |
| `cut` |  |
| `delete` | removes the clip and leaves a gap |
| `delete_audio_preset` |  |
| `delete_look` |  |
| `delete_marker` |  |
| `delete_selected` | deletes every selected clip and graphic; ripple=true (or magnetic on) closes gaps left by clips |
| `delete_title` |  |
| `detach_audio` | ONE idea for every video track (V1 included): a clip's sound is either linked to it or not (⌘L toggles, ⌃⇧S too). Unlink: the sound becomes its own clip in place and moves on its own. Link: selected sound follows the selected picture. |
| `discard_recovery` |  |
| `drag_edit` | clip=<id> mode=trim_start/trim_end/move delta=<seconds> [magnet_range=<seconds>] Same code path as dragging with the mouse. |
| `duplicate_project` | path=<new file> [vertical=true] : a copy of this project (vertical: 9:16 with every clip filling the frame) |
| `export` | out= [container=mp4/mov/m4v/m4a/wav] [codec=h264/hevc/prores422lt/prores422/prores422hq/prores4444] [mbps=] [width= height=] [audio=aac/pcm] [kbps=] [from= to=] [overwrite=true] |
| `get_project` |  |
| `group` | ids= (default: selection) [name=] : ties them together (⌘G) |
| `import_fcpxml` | path=<.fcpxmld or .fcpxml> out=<project.cutgenie.json to write>. Read-only on the Final Cut project. |
| `layer_fx` | ids=g1,g2 type=shadow/glow/stroke/corners/blur/color/tint [any effect number, e.g. distance=20]  (adds an effect) |
| `layer_set` | ids=g1,g2 [x= y= (px from centre) scale= rotation= opacity=] [crop=l,r,t,b] [blend=] [fade_in= fade_out=] [clear_fx=true] (at= timeline time) |
| `lib_add` | path=<folder or file>[,<more>] : adds to the media library (testing / automation) |
| `lib_list` |  |
| `link_audio` | ONE idea for every video track (V1 included): a clip's sound is either linked to it or not (⌘L toggles, ⌃⇧S too). Unlink: the sound becomes its own clip in place and moves on its own. Link: selected sound follows the selected picture. |
| `list_audio_presets` |  |
| `list_looks` |  |
| `magnetic_drop_x` | clip= delta= : where a magnetic move would land (time of the insertion point) |
| `match_clip` | asset=<id> or path= : take that clip's size and frame rate for the project |
| `match_input_luts` | every clip without an Input LUT gets the one other clips of the same kind (HLG / PQ) already use |
| `match_loudness` | sets Output gain so the integrated loudness reaches target= (default -14 LUFS); the limiter (if on) keeps peaks under its ceiling |
| `move` |  |
| `move_clip_key` | id= from= to= : every keyframe of the clip at time `from` (transform and zoom) moves to `to` (seconds in the clip) |
| `move_items` | ids= (default: selection) delta=<seconds> : moves all of them by the same amount, each on its own track |
| `move_marker` |  |
| `new_project` | path= [width=] [height=] [fps=] : an empty project saved there and opened |
| `next_marker` |  |
| `nudge` | frames= : move the selected clip or graphic by whole frames (Final Cut , and .) |
| `open` |  |
| `overlay_delete` |  |
| `overlay_edit` | id=<graphic id> [offset=] [duration=] [trim_start=<seconds to remove from the start, negative extends>] |
| `paste` | at= (default playhead). Clips are inserted into the main storyline (later clips move right); graphics and audio clips go on top at the same relative times, each on the first track with room. |
| `paste_attrs` | ids= parts=all/transform,zoom,crop,shadow,color : the copied clip's look onto these clips (Final Cut Paste Attributes) |
| `paste_grade` | ids= (default: selected clips): gives them the copied grade (replaces theirs). One undo step. |
| `pause` |  |
| `pip` | clip=<V2+ clip> [x= y= px from centre] [scale=] [rotation=] [opacity=] [crop=l,r,t,b] |
| `play` | a player that died (sound device switched, decoder error...) gets a fresh one instead of staying silent and frozen |
| `play_speed` | speed= : how fast the viewer plays (0.5, 1, 1.25, 1.5, 2, 3, 4...). Does not change the edit. |
| `playback_scale` | scale=1/0.5/0.25 - viewer playback resolution |
| `previous_marker` |  |
| `project_settings` | [width=] [height=] [fps=] [fit=fit/fill/none] : the project's format (Project settings window) |
| `quit` | save (when the project has a file) and close Cutgenie cleanly; used for restarts after an install |
| `redo` |  |
| `relink_audio` | id=<audio clip> : links an unlinked sound to its video clip again |
| `relink_folder` | dir= [all=true] : missing media files (or, with all, every file) are looked for by name in that folder and its sub-folders |
| `remove_empty_tracks` | drops empty video / audio tracks at the top of the stack |
| `remove_eq` |  |
| `remove_lut` |  |
| `rename_group` |  |
| `rename_marker` |  |
| `render_frame` | [scale=0.5] renders the way half-resolution playback draws it (for checking) |
| `restore_recovery` |  |
| `restore_version` | file= : an earlier saved version replaces the timeline (one undo step; nothing is saved until you save) |
| `resync_audio` | id=<audio clip> : moves an unlinked / linked sound back in line with its video clip |
| `ripple_delete` | clip=<id>: remove it and pull everything after it (clips and lower thirds) left to close the gap. or from=<t> to=<t>: remove that time range across clips, then close the gap. |
| `roll` | at=<edit point time> delta= : moves the cut between two touching clips; total length stays the same (Trim tool on an edit point) |
| `save` |  |
| `save_audio_preset` | name= [track=]: saves a track's effects for every project (Audio panel > Presets) |
| `save_look` | name= [clip=]: saves the grade for every project (Color panel > Looks) |
| `save_title` | name= [ids= default the selection]: saves those text / shape layers (with their look and animation) as a reusable title |
| `scroll_by` | dx= dy= : move the timeline view (testing smoothness) |
| `seek` |  |
| `segments` | testing aid: the picture track's segments between from= and to= |
| `select` |  |
| `select_forward` | at= : selects everything that starts at or after this time, on every track |
| `select_items` | ids=a,b,c (clip or graphic ids)  [add=true]   or  all=true |
| `set_asset_paths` | paths={asset id: new path} (after Collect media copied the files) |
| `set_audio` |  |
| `set_color` |  |
| `set_comp` |  |
| `set_display` | gamma=<0.8...1.1> : window-only display curve (testing aid / same as the panel slider) |
| `set_eq` | band=<index> (index = count adds a band, max 10) type=bell/lowshelf/highshelf/highpass/lowpass/notch freq= gain= q= enabled=   or eq_enabled= |
| `set_fade` | id=<clip or audio clip> [in=<seconds>] [out=<seconds>] |
| `set_gate` |  |
| `set_limiter` |  |
| `set_lut` | clip= or same_media_as=  slot=input/creative/output (default output)  path=<file.cube> or asset=<id>  [intensity=0..1] [enabled=true/false] |
| `set_mode` | magnetic=true/false snapping=true/false |
| `set_output` |  |
| `set_setting` | key=colorPipeline value=raw/managed   key=colorSpace value=<project output space>   key=hdrToSdr value=soft/clip |
| `set_speed` | clip=<V1 or V2+ clip> speed=<0.1...8> : retime the clip (2 = twice as fast, half as long). The rest moves to make room. |
| `set_tool` |  |
| `set_volume` | id=<clip or audio clip> [gain_db=] [keys="t:db,t:db,..." (t from clip start; keys="" removes them)] |
| `set_wheels` | clip= or same_media_as=  wheel=global/shadows/midtones/highlights  hue= amount= saturation= brightness= r= g= b= [preserve_luma=true/false] [mix=0..1] [live=true] |
| `show` | tab=color/audio : which panel the window shows |
| `shuttle` | rate= : J/K/L style playback speed (negative = backwards) |
| `simplify_keys` | ids= (or all=true): keep only the keyframes that shape each move (zoom and transform), easing between them |
| `skim` | time=<s> or off=true : testing aid for the skimmer |
| `slide` | clip= delta= : moves a clip between its neighbours; the one before gets longer/shorter, the one after the opposite (⌥ Trim tool) |
| `slip` | clip= delta= : shows a different part of the media, same position and length (Trim tool in the middle of a clip) |
| `slow_motion` | clip= : a high-frame-rate clip plays every recorded frame (60 fps in a 23.98 project = 40 % smooth slow motion) |
| `split` |  |
| `status` |  |
| `sync_clips` | ids= (default: selection) [ref=<id>] : lines the clips up with the reference by their SOUND (multi-camera, separate mic). Reference = ref=, else the selected V1 clip, else the lowest video track, else the first audio clip. Only V2+ video |
| `sync_lock` | track=V5/A2 on=true/false : sync lock (on = the track follows V1 ripple edits) |
| `text_edit` | id= [run= 0] [text=] [font=] [size=] [bold=] [italic=] [color=r,g,b,a] [tracking=] [stroke_color=] [stroke_width=] [shadow_color=] [shadow_distance=] [shadow_blur=] [shadow_angle=] [align=left/center/right] [line_spacing=] [width= 0 = no wrap] |
| `to_lane` | clip=<id> lane=<0 = V1 main storyline, 1 = V2, 2 = V3...> at=<new start> V1 -> V2+: the clip is lifted out and leaves a gap (everything else stays in sync), Final Cut "Lift from Storyline" |
| `toggle_enabled` | ids= (default: selection): switch clips / graphics / sound off or back on (Final Cut "V"). Off = not seen / heard, kept on the timeline |
| `toggle_link` | ONE idea for every video track (V1 included): a clip's sound is either linked to it or not (⌘L toggles, ⌃⇧S too). Unlink: the sound becomes its own clip in place and moves on its own. Link: selected sound follows the selected picture. |
| `track_height` | track=V1/V2/A1... h=<points> (same as dragging the line under the track name) |
| `track_hidden` | track=V3/A2 on=true/false : hide a video track / mute an audio track (playback + export) |
| `trim` | clip=<id> edge=start/end to=<timeline time>. Start trims move the in-point; the clip's end stays put. |
| `undo` |  |
| `ungroup` |  |
| `upper_trim` | clip=<id on V2+> [trim_start=<seconds removed from the start, negative extends>] [duration=] |
| `zoom` | pps=<pixels per second> : timeline zoom (same as the slider / ⌘+scroll) |

## Testing aids

Used by the test suites to drive and inspect the interface; not needed for editing.

| Command | Notes |
|---|---|
| `audio_debug` |  |
| `convert_probe` | from= to= (colour space ids) r= g= b= (0...1) [tone_map=soft/clip]: runs the real conversion on one colour |
| `fx_stats` |  |
| `inspector_tab` |  |
| `live_bench` | testing aid: n= live moves of layer id= by 1 unit each, timed through the live redraw path |
| `mix_check` | volume the PLAYING item applies on its first audio track at t= (from its own mix, not ours) |
| `pointer_png` | testing aid: writes the blade pointer image to out= |
| `probe_player` | Testing aid: grabs the frame the LIVE PLAYER composes at time= (what you see in the window) and saves it as PNG. |
| `snapshot_ui` | Testing aid: the app renders its own interface (view=color/window) to a PNG. Needs no screen permission. |
| `ui_key` | testing aid: key=<character or name: space left right up down home end delete escape> mods=shift,command,option |
| `ui_mouse` | testing aid: path="x,y;x,y;..." in window points (top-left origin), mods=shift,command,option ; down at first, drag, up at last |
| `ui_open` |  |
| `ui_png` |  |
| `ui_scroll` | testing aid: a scroll-wheel event at x,y (window points, top-left) with dy lines, mods=shift,command, precise=true |
| `ui_state` |  |
| `ui_window` |  |
