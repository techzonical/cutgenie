#!/usr/bin/env python3
"""Quick test anyone can run - no footage needed.

Makes two short test clips with ffmpeg (colour bars + a tone, a moving test pattern + another tone), builds a small
project from them, starts a separate Cutzonical on port 7879 and checks the basics:
  open      the project opens with its clips
  edit      split + undo work and the clip count comes back
  text      a text layer can be added
  export    a 4 s export is written, has picture and sound, and is the right length
Usage:  python3 tests/smoke.py [path/to/Cutzonical binary]      (default: .build/release/Cutzonical)
Needs: ffmpeg / ffprobe on PATH, and `swift build -c release` done first.
"""
import json, os, signal, subprocess, sys, tempfile, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BIN = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, ".build/release/Cutzonical")
CTL = os.path.join(ROOT, ".build/release/cutzonicalctl")
PORT = "7879"
WORK = tempfile.mkdtemp(prefix="cutzonical-smoke-")
env = dict(os.environ, CUTZONICAL_PORT=PORT, CUTZONICAL_AWAKE="1")
fails = []


def check(name, ok, detail=""):
    print(f"{'PASS' if ok else 'FAIL'}  {name:8s} {detail}")
    if not ok:
        fails.append(name)


def ctl(*a, timeout=180):
    r = subprocess.run([CTL, *a], env=env, capture_output=True, text=True, timeout=timeout)
    try:
        return json.loads(r.stdout)
    except Exception:
        return {"ok": False, "error": (r.stdout + r.stderr).strip()}


def ff(*a):
    subprocess.run(["ffmpeg", "-v", "error", "-y", *a], check=True)


def probe(path, entry):
    r = subprocess.run(["ffprobe", "-v", "error", "-show_entries", entry, "-of", "default=nw=1:nk=1", path], capture_output=True, text=True)
    return r.stdout.split()


def port_pids():
    r = subprocess.run(["lsof", "-nP", f"-iTCP:{PORT}", "-sTCP:LISTEN", "-t"], capture_output=True, text=True)
    return [int(x) for x in r.stdout.split()]


for tool in ("ffmpeg", "ffprobe"):
    if subprocess.run(["which", tool], capture_output=True).returncode != 0:
        sys.exit(f"{tool} is needed for this test (brew install ffmpeg)")
if not os.path.exists(BIN) or not os.path.exists(CTL):
    sys.exit("build first: swift build -c release")

# two 6-second test clips, 1080p 30 fps, with sound
a = os.path.join(WORK, "bars.mp4"); b = os.path.join(WORK, "pattern.mp4")
ff("-f", "lavfi", "-i", "smptehdbars=s=1920x1080:r=30:d=6", "-f", "lavfi", "-i", "sine=frequency=440:duration=6",
   "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest", a)
ff("-f", "lavfi", "-i", "testsrc2=s=1920x1080:r=30:d=6", "-f", "lavfi", "-i", "sine=frequency=880:duration=6",
   "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest", b)


def clip(i, asset, src_in, dur, off):
    return {"id": f"c{i}", "asset": asset, "sourceIn": src_in, "duration": dur, "offset": off, "audio": {"gainDb": 0},
            "color": {"exposure": 0, "contrast": 1, "saturation": 1, "temperature": 6500}}


proj = os.path.join(WORK, "smoke.cutzonical.json")
json.dump({"version": 1, "name": "smoke", "titles": [],
           "assets": [{"id": "a", "path": a}, {"id": "b", "path": b}],
           "clips": [clip(1, "a", 0, 3, 0), clip(2, "b", 1, 3, 3)],
           "settings": {"width": 1920, "height": 1080, "fps": 30, "colorSpace": "rec709"}}, open(proj, "w"))

for p in port_pids():
    os.kill(p, signal.SIGTERM)
subprocess.Popen([BIN], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
for _ in range(60):
    if port_pids():
        break
    time.sleep(0.5)
else:
    sys.exit("Cutzonical did not start")

try:
    r = ctl("open", f"path={proj}")
    st = ctl("status")
    check("open", r.get("ok") is True and st.get("clips") == 2, f"{st.get('clips')} clips, {r.get('duration', 0):.1f} s")

    ctl("split", "at=1.5"); n1 = ctl("status").get("clips"); ctl("undo"); n2 = ctl("status").get("clips")
    check("edit", n1 == 3 and n2 == 2, f"split -> {n1} clips, undo -> {n2}")

    r = ctl("add_text")
    check("text", r.get("ok") is True, r.get("error", "") or "added")

    out = os.path.join(WORK, "out.mp4")
    r = ctl("export", f"out={out}", "from=1", "to=5", "codec=hevc", "mbps=8", "overwrite=true")
    dur = float((probe(out, "format=duration") or ["0"])[0]) if os.path.exists(out) else 0
    streams = probe(out, "stream=codec_type") if os.path.exists(out) else []
    check("export", r.get("ok") is True and abs(dur - 4) < 0.15 and "video" in streams and "audio" in streams,
          f"{dur:.2f} s, streams {', '.join(streams) or 'none'}")
finally:
    for p in port_pids():
        os.kill(p, signal.SIGTERM)

print(f"\n{4 - len(fails)} of 4 smoke checks passed  (files in {WORK})")
sys.exit(1 if fails else 0)
