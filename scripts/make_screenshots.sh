#!/bin/zsh
# Makes the documentation screenshots in docs/images/ from a SEPARATE test copy of Cutgenie on port 7879.
# It never touches the Cutgenie you use every day (port 7878) or any of your projects.
#
#   zsh scripts/make_screenshots.sh            # all chapters
#   zsh scripts/make_screenshots.sh 01         # only chapters whose folder starts with 01
#
# Footage: by default it makes test clips with ffmpeg. To use your own sample footage instead, put
# clip1.mp4, clip2.mp4, clip3.mp4 (and optionally music.m4a) in a folder and run with
#   CUTGENIE_SAMPLE_MEDIA=/path/to/folder zsh scripts/make_screenshots.sh
# Needs: `zsh scripts/build_app.sh` done first, ffmpeg, and Python with Pillow (for cropping).
set -e
cd "$(dirname "$0")/.."
ROOT=$PWD
ONLY=${1:-}
export CUTGENIE_PORT=7879 CUTGENIE_AWAKE=1
BIN=.build/release/Cutgenie
CTL=.build/release/cutgeniectl
IMG=docs/images
WORK=$(mktemp -d /tmp/cutgenie-shots-XXXX)
export CUTGENIE_LIBRARY=$WORK/library.json        # a throwaway media library, not yours
W=1440 H=900                                   # window size of every screenshot (points)

[[ -x $BIN && -x $CTL ]] || { echo "build first: zsh scripts/build_app.sh"; exit 1; }
ctl() { $CTL "$@" >/dev/null }
want() { [[ -z $ONLY || $1 == $ONLY* ]] }
stop_test_app() { for p in $(lsof -nP -iTCP:7879 -sTCP:LISTEN -t 2>/dev/null); do kill $p; done; sleep 1 }
# shot <file under docs/images> : saves the main window (or its open sheet) as PNG
# (uses macOS screencapture on the app's window: the first run asks to allow Screen Recording for your terminal)
shot() {
  mkdir -p "$IMG/${1:h}"; sleep 1
  local id=$($CTL ui_window | python3 -c 'import json,sys;print(json.load(sys.stdin).get("window",0))')
  screencapture -x -o -l $id "$IMG/$1" 2>/dev/null && { echo "  $1"; return 0 }
  echo "FAILED $1: macOS refused the capture. Is the screen locked or asleep, or is Screen Recording not allowed?"; exit 1
}

# crop <file> <x> <y> <w> <h> : keep one part of a window shot (pixels in the 2x image; the window is 2880x1782)
crop() { python3 -c 'import sys;from PIL import Image;f,x,y,w,h=sys.argv[1],*map(int,sys.argv[2:]);Image.open(f).crop((x,y,x+w,y+h)).save(f)' "$IMG/$1" $2 $3 $4 $5 && echo "    cropped" }
# panel regions of the 1440x900 window
MEDIA_R=(0 60 880 650); INSP_R=(1924 60 956 650)
part() { local f=$1; shift; shot $f; crop $f "$@" }
# tall / short : drag the line under the viewer down so the inspector is tall, and back again (for inspector close-ups)
tall()  { ctl ui_split top=860 }
short() { ctl ui_split top=330 }
TALL_R=(1924 60 956 1400)
# sec <file> <section keys> : inspector close-up showing only those sections (keys as in InspectorSection, e.g. wheels,a.eq)
sec() { tall; ctl ui_sections only=$2; part $1 $TALL_R; ctl ui_sections all=open; short }
TOP_R=(0 0 2880 200); TL_R=(0 720 2880 480); EXP_R=(740 160 1400 1460)
# iscroll <lines> : scroll the inspector down (negative: up)
iscroll() { ctl ui_scroll x=1200 y=450 dy=$((0 - $1)) }
# find <word> : type into the inspector's "Find a setting" box so only matching sections show; find "" clears it
find() { ctl ui_mouse path="1060,66"; ctl ui_key key=a mods=command; ctl ui_key key=delete; [[ -n $1 ]] && ctl ui_key key="$1"; sleep 0.5 }

# ---- sample footage (swappable) ----
MEDIA=${CUTGENIE_SAMPLE_MEDIA:-$WORK/media}
if [[ -z $CUTGENIE_SAMPLE_MEDIA ]]; then
  mkdir -p $MEDIA
  ff() { ffmpeg -v error -y "$@" }
  ff -f lavfi -i "testsrc2=s=1920x1080:r=30:d=8" -f lavfi -i "sine=frequency=440:duration=8" -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest $MEDIA/clip1.mp4
  ff -f lavfi -i "smptehdbars=s=1920x1080:r=30:d=6" -f lavfi -i "sine=frequency=660:duration=6" -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest $MEDIA/clip2.mp4
  ff -f lavfi -i "gradients=s=1920x1080:r=30:d=7:speed=0.02" -f lavfi -i "sine=frequency=330:duration=7" -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest $MEDIA/clip3.mp4
  ff -f lavfi -i "sine=frequency=220:duration=20" -c:a aac $MEDIA/music.m4a
fi

# ---- start the test copy ----
stop_test_app
# The bare .build binary keeps its settings under the name "Cutgenie" (not com.techzonical.cutgenie, the installed
# app), so clearing its tab and recent-project lists here never touches your own settings.
for k in projectTabs projects.recent projects.recentFolders lastProject; do defaults delete Cutgenie $k >/dev/null 2>&1 || true; done
$BIN >/dev/null 2>&1 &
for i in {1..60}; do lsof -nP -iTCP:7879 -sTCP:LISTEN -t >/dev/null 2>&1 && break; sleep 0.5; done
trap stop_test_app EXIT
sleep 2
ctl ui_size w=$W h=$H

# ---- 01 Getting started (the sample project is always made: later chapters need it) ----
want 01 && echo "01-getting-started"
want 01 && shot 01-getting-started/first-launch.png               # empty window, nothing open yet
ctl ui_key key=escape
ctl new_project path=$WORK/Sample.cutgenie.json width=1920 height=1080 fps=30; sleep 2
ctl ui_size w=$W h=$H
want 01 && shot 01-getting-started/empty-project.png
ctl add_clip path=$MEDIA/clip1.mp4
ctl add_clip path=$MEDIA/clip2.mp4
ctl add_clip path=$MEDIA/clip3.mp4
ctl lib_add path=$MEDIA
ctl seek time=3
if want 01; then
  shot 01-getting-started/sample-project.png
  ctl ui_open what=new; shot 01-getting-started/new-project-sheet.png; ctl ui_key key=escape
fi

# ---- 02 Interface ----
if want 02; then
  echo "02-interface"
  ctl lib_add path=$MEDIA; ctl ui_key key=z mods=shift; ctl select clip=c2 ids=c2; ctl seek time=10
  ctl inspector_tab tab=clip
  shot 02-interface/window-tour.png
  part 02-interface/media-panel.png $MEDIA_R
  part 02-interface/inspector-effects.png $INSP_R
  ctl inspector_tab tab=color; part 02-interface/inspector-colour.png $INSP_R
  ctl inspector_tab tab=audio; part 02-interface/inspector-audio.png $INSP_R
  ctl inspector_tab tab=clip
  shot 02-interface/timeline.png
  ctl ui_key key=t mods=shift,command; shot 02-interface/big-timeline.png; ctl ui_key key=t mods=shift,command
fi

# ---- 03 Projects ----
if want 03; then
  echo "03-projects"
  ctl save; ctl set_color clip=c1 exposure=0.3; ctl save; ctl set_color clip=c1 exposure=0; ctl save
  ctl ui_open what=browser;  shot 03-projects/project-browser.png;  ctl ui_key key=escape
  ctl ui_open what=settings; shot 03-projects/project-settings.png; ctl ui_key key=escape
  ctl ui_open what=versions; shot 03-projects/versions.png;         ctl ui_key key=escape
  ctl new_project path=$WORK/Second.cutgenie.json width=1920 height=1080 fps=30; sleep 2; ctl ui_size w=$W h=$H
  part 03-projects/project-tabs.png 0 700 1400 160
  ctl open path=$WORK/Sample.cutgenie.json; sleep 2; ctl ui_size w=$W h=$H
fi

# ---- 04 Importing ----
if want 04; then
  echo "04-importing"
  ctl lib_add path=$MEDIA
  part 04-importing/media-library.png 0 60 880 640
  ctl ui_mouse path="357,43"; part 04-importing/list-view.png 0 60 880 640; ctl ui_mouse path="325,43"
fi

# ---- 05 Editing basics ----
if want 05; then
  echo "05-editing-basics"
  ctl ui_key key=z mods=shift; ctl select clip=c1 ids=c1; ctl seek time=4
  shot 05-editing-basics/playhead.png
  ctl split at=4; ctl select clip=c2 ids=c2
  shot 05-editing-basics/after-blade.png
  ctl undo
  ctl add_marker at=2 name="Intro ends"; ctl add_marker at=12 name="Best bit"
  shot 05-editing-basics/markers.png
  ctl set_speed clip=c3 speed=0.5
  shot 05-editing-basics/speed.png
  ctl undo
  ctl add_clip path=$MEDIA/clip1.mp4; ctl ui_key key=z mods=shift; part 05-editing-basics/append.png $TL_R; ctl undo
  ctl select clip=c2 ids=c2; ctl ui_key key=delete mods=shift; ctl ui_key key=z mods=shift; part 05-editing-basics/lift-gap.png $TL_R; ctl undo
  ctl ripple_delete clip=c2; ctl ui_key key=z mods=shift; part 05-editing-basics/ripple-delete.png $TL_R; ctl undo
  ctl ui_key key=z mods=shift
  ctl set_tool tool=trim; ctl select clip=c2 ids=c2; part 05-editing-basics/trim-tool.png $TL_R; ctl set_tool tool=select
  ctl to_lane clip=c3 lane=1 at=9; ctl select clip=c3 ids=c3; part 05-editing-basics/move-up.png $TL_R; ctl undo
  ctl group ids=c1,c2 name="Intro"; part 05-editing-basics/group.png $TL_R; ctl undo
  part 05-editing-basics/undo-buttons.png 0 1470 120 130
fi

# ---- 06 Picture ----
if want 06; then
  echo "06-picture"
  ctl seek time=10; ctl select clip=c2 ids=c2; ctl inspector_tab tab=clip
  sec 06-picture/transform.png pip.transform
  sec 06-picture/zoom.png pip.zoom
  sec 06-picture/crop.png pip.crop
  ctl seek time=8.5; ctl ui_key key=down; ctl ui_key key=up; ctl select clip=c2 ids=c2
  sec 06-picture/keyframes.png pip.keys,pip.zoom
  ctl to_lane clip=c3 lane=1 at=9; ctl pip clip=c3 x=560 y=300 scale=0.35; ctl seek time=11; ctl select clip=c3 ids=c3
  shot 06-picture/picture-in-picture.png
  ctl undo; ctl undo; ctl seek time=10
  ctl select clip=c2 ids=c2; ctl add_adjustment; part 06-picture/adjustment-layer.png $TL_R; ctl undo
fi

# ---- 07 Colour ----
if want 07; then
  echo "07-colour"
  ctl seek time=10; ctl select clip=c2 ids=c2; ctl inspector_tab tab=color
  tall; ctl ui_sections only=wheels; part 07-colour/wheels.png $TALL_R; ctl ui_sections all=open; short
  ctl seek time=10; ctl select clip=c2 ids=c2; ctl set_color clip=c2 exposure=0.2 saturation=1.25 temperature=0.15
  ctl inspector_tab tab=color; part 07-colour/basic.png $INSP_R
  ctl undo
  sec 07-colour/luts.png input,looks
  ctl inspector_tab tab=clip
fi

# ---- 08 Graphics ----
if want 08; then
  echo "08-graphics"
  ctl seek time=2; ctl add_text text="Welcome" at=1; sleep 1; ctl seek time=2.5
  shot 08-graphics/text.png
  sec 08-graphics/style-text.png fx.text
  sec 08-graphics/animate.png fx.build,fx.fade,fx.behave
  ctl undo
  ctl add_shape kind=rect at=1; sleep 1; ctl seek time=2.5
  shot 08-graphics/shape.png
  sec 08-graphics/shape-settings.png fx.shape
  ctl layer_fx ids=g1 type=shadow; ctl layer_fx ids=g1 type=stroke
  sec 08-graphics/layer-effects.png fx.effects
  ctl undo; ctl undo; ctl undo
  ctl seek time=10; ctl add_shape kind=blur at=9; sleep 1; ctl seek time=10.5
  shot 08-graphics/blur-area.png
  ctl undo; ctl ui_key key=escape
fi

# ---- 09 Sound ----
if want 09; then
  echo "09-sound"
  ctl seek time=10; ctl select clip=c2 ids=c2; ctl inspector_tab tab=clip
  sec 09-sound/volume.png clip.volume,clip.fades
  ctl set_fade id=c2 in=1 out=1.5; part 09-sound/fades.png $TL_R; ctl undo
  ctl add_audio path=$MEDIA/music.m4a at=0; ctl ui_key key=z mods=shift; part 09-sound/music.png $TL_R; ctl undo
  ctl inspector_tab tab=audio
  sec 09-sound/clean-voice.png a.gate,a.eq,a.comp
  sec 09-sound/loudness.png a.out,a.loud
  ctl inspector_tab tab=clip
fi

# ---- 10 Exporting ----
if want 10; then
  echo "10-exporting"
  ctl ui_open what=export; shot 10-exporting/export-window.png
  ctl ui_key key=escape
  ctl ui_open what=export; part 10-exporting/presets.png 740 330 1400 270; ctl ui_key key=escape
  ctl ui_open what=export; part 10-exporting/custom.png 740 940 1400 520; ctl ui_key key=escape
  ctl select clip=c2 ids=c1,c2; ctl ui_open what=export; part 10-exporting/range.png 740 940 1400 520; ctl ui_key key=escape
  touch $WORK/Untitled.mp4; ctl ui_open what=export; part 10-exporting/already-there.png 740 580 1400 360; ctl ui_key key=escape
fi

# ---- 11 Shortcuts ----
if want 11; then
  echo "11-shortcuts"
  ctl ui_open what=shortcuts; shot 11-shortcuts/keyboard-map.png
  ctl ui_key key=escape
fi

echo "done: images are in $IMG/"
