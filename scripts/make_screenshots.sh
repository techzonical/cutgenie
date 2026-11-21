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
  screencapture -x -o -l $id "$IMG/$1" && echo "  $1" || echo "  FAILED $1"
}

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

echo "done: images are in $IMG/"
