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
# Needs: `zsh scripts/build_app.sh` done first, and ffmpeg.
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
crop() { sips -c $5 $4 --cropOffset $3 $2 "$IMG/$1" >/dev/null && echo "    cropped" }
# panel regions of the 1440x900 window
MEDIA_R=(0 60 880 860); INSP_R=(1924 60 956 860)
part() { local f=$1; shift; shot $f; crop $f "$@" }

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

# ---- 01 Getting started ----
if want 01; then
  echo "01-getting-started"
  shot 01-getting-started/first-launch.png                       # empty window, nothing open yet
  ctl ui_key key=escape
  ctl new_project path=$WORK/Sample.cutgenie.json width=1920 height=1080 fps=30; sleep 2
  ctl ui_size w=$W h=$H
  shot 01-getting-started/empty-project.png
  ctl add_clip path=$MEDIA/clip1.mp4
  ctl add_clip path=$MEDIA/clip2.mp4
  ctl add_clip path=$MEDIA/clip3.mp4
  ctl seek time=3
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
fi

# ---- 04 Importing ----
if want 04; then
  echo "04-importing"
  ctl lib_add path=$MEDIA
  part 04-importing/media-library.png 0 60 880 640
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
fi

echo "done: images are in $IMG/"
