#!/usr/bin/env python3
"""Cutgenie check suite: run before installing a new build.

Builds small test projects from real footage (read only - media and the user's projects are never changed),
starts a separate Cutgenie on port 7879, and checks the bugs we have already fixed once:
  rotation      iPhone clip with a turn flag shows upright and fills the frame
  frame timing  export around cuts has evenly spaced frames (no blink)
  sound         sound keeps going across a 44.1 kHz mono -> 48 kHz stereo file switch
  playback      the player runs through that switch without getting stuck
  transform     V1 keyframed scale / position renders (picture shrinks over time)
  zoom          V1 zoom keyframes render
  autosave      unsaved changes are found again after a crash
Usage:  python3 tests/check_all.py [path/to/Cutgenie binary]      (default: .build/release/Cutgenie)
"""
import json, os, subprocess, sys, time, signal, shutil, tempfile, struct

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BIN = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, ".build/release/Cutgenie")
CTL = os.path.join(ROOT, "build/cutgeniectl")
# a folder with your own test footage (read only), see docs/13-reference/08-testing.mdx:
#   IMG_1640.MOV (iPhone HEVC, turned), a-roll-audio.wav (separate voice, 44.1 kHz mono), "Final MyPCKey sponsor message video.mov" (48 kHz stereo)
SRC = os.environ.get("CUTGENIE_FOOTAGE", "")
BIG = os.environ.get("CUTGENIE_BIG_PROJECT", "")     # optional: a long real project for the speed check
PORT = "7879"
OUT = tempfile.mkdtemp(prefix="cutgenie-check-")
PROJ = OUT            # scratch test projects live in a temporary folder, never in the repository
TIMING = os.path.join(tempfile.gettempdir(), "cutgenie-check-timing.txt")
env = dict(os.environ, CUTGENIE_PORT=PORT, CUTGENIE_AWAKE="1", CUTGENIE_TIMING=TIMING)
results = []


def ctl(*args, timeout=180):
    r = subprocess.run([CTL, *args], env=env, capture_output=True, text=True, timeout=timeout)
    try:
        return json.loads(r.stdout)
    except Exception:
        return {"ok": False, "error": (r.stdout + r.stderr).strip()}


def port_pid():
    r = subprocess.run(["lsof", "-nP", f"-iTCP:{PORT}", "-sTCP:LISTEN", "-t"], capture_output=True, text=True)
    return [int(x) for x in r.stdout.split()]


def start():
    for p in port_pid():
        os.kill(p, signal.SIGTERM)
    time.sleep(0.5)
    subprocess.Popen([BIN], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for _ in range(60):
        if port_pid():
            return
        time.sleep(0.5)
    raise SystemExit("Cutgenie did not start")


def stop(hard=False):
    for p in port_pid():
        os.kill(p, signal.SIGKILL if hard else signal.SIGTERM)
    time.sleep(0.8)


def check(name, ok, detail=""):
    results.append((name, ok, detail))
    print(f"{'PASS' if ok else 'FAIL'}  {name:13s} {detail}")


def ff(*args):
    return subprocess.run(["ffmpeg", "-v", "error", "-y", *args], capture_output=True, text=True)


def mean_db(wav, start, dur):
    r = subprocess.run(["ffmpeg", "-hide_banner", "-ss", str(start), "-t", str(dur), "-i", wav, "-af", "volumedetect", "-f", "null", "-"],
                       capture_output=True, text=True)
    for line in r.stderr.splitlines():
        if "mean_volume" in line:
            return float(line.split(":")[1].split()[0])
    return -999.0


def gray(png, x, y):
    """average brightness of a small patch (0..255) of a picture, via ffmpeg"""
    r = subprocess.run(["ffmpeg", "-v", "error", "-i", png, "-vf", f"crop=40:40:{x}:{y},scale=1:1", "-f", "rawvideo", "-pix_fmt", "gray", "-"],
                       capture_output=True)
    return r.stdout[0] if r.stdout else -1


def project(name, clips, extra=None):
    assets = [
        {"id": "cam", "path": f"{SRC}/IMG_1640.MOV"},
        {"id": "voice", "path": f"{SRC}/a-roll-audio.wav"},
        {"id": "sponsor", "path": f"{SRC}/Final MyPCKey sponsor message video.mov"},
    ]
    d = {"version": 1, "name": name, "assets": assets, "clips": clips, "titles": [],
         "settings": {"width": 1920, "height": 1080, "fps": 30, "colorSpace": "rec709"}}
    if extra:
        d.update(extra)
    p = os.path.join(PROJ, f"_check_{name}.cutgenie.json")
    json.dump(d, open(p, "w"))
    return p


def clip(id, asset, src_in, dur, off, **kw):
    c = {"id": id, "asset": asset, "sourceIn": src_in, "duration": dur, "offset": off, "audio": {"gainDb": 0},
         "color": {"exposure": 0, "contrast": 1, "saturation": 1, "temperature": 6500}}
    c.update(kw)
    return c


def main():
    if not SRC or not os.path.exists(SRC):
        raise SystemExit("set CUTGENIE_FOOTAGE to your test footage folder (see docs/13-reference/08-testing.mdx); for a quick test without footage run tests/smoke.py")
    # test projects: camera cuts with the voice file as sound, then the sponsor video, then camera again
    base = [clip("c1", "cam", 100, 3, 0, audioSource={"asset": "voice", "sourceIn": 102}),
            clip("c2", "cam", 140, 3, 3, audioSource={"asset": "voice", "sourceIn": 142}),
            clip("c3", "cam", 200, 2, 6, audioSource={"asset": "voice", "sourceIn": 202}),
            clip("c4", "sponsor", 5, 6, 8),
            clip("c5", "cam", 118, 4, 14, audioSource={"asset": "voice", "sourceIn": 120})]
    p_main = project("main", base)
    anim = json.loads(json.dumps(base))
    anim[1]["xf"] = {"keys": {"scale": [{"t": 0, "v": [1]}, {"t": 2, "v": [0.5], "e": "s"}]}}
    anim[4]["zoom"] = [{"t": 0, "v": [1]}, {"t": 3, "v": [1.3], "e": "s"}]
    p_anim = project("anim", anim)

    start()
    try:
        r = ctl("open", f"path={p_main}")
        check("open", r.get("ok") is True, f"{r.get('duration', 0):.1f} s" if r.get("ok") else r.get("error", ""))

        # rotation: the phone clip fills the frame (no black bars left / right)
        png = os.path.join(OUT, "rot.png")
        ctl("render_frame", "time=1", f"out={png}")
        left, mid = gray(png, 5, 520), gray(png, 940, 520)
        check("rotation", left > 25 and mid > 25, f"left edge {left}, middle {mid} (black bars would be ~0)")

        # frame timing: evenly spaced frames across the cuts
        mp4 = os.path.join(OUT, "cuts.mp4")
        r = ctl("export", f"out={mp4}", "from=1", "to=10", "overwrite=true")
        pts = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v", "-show_entries", "frame=pts_time", "-of", "csv=p=0", mp4],
                             capture_output=True, text=True).stdout.split()
        ts = [float(x.strip(",")) for x in pts if x.strip(",")]
        bad = sum(1 for a, b in zip(ts, ts[1:]) if not (0.03 <= b - a <= 0.037))
        check("frame timing", r.get("ok") and len(ts) > 200 and bad == 0, f"{len(ts)} frames, {bad} uneven")

        # sound across the format switch (voice 44.1 kHz mono -> sponsor 48 kHz stereo -> voice)
        wav = os.path.join(OUT, "snd.wav")
        r = ctl("export", f"out={wav}", "audio=pcm", "overwrite=true")
        levels = [mean_db(wav, s, 1.5) for s in (1, 9.5, 15.5)]
        check("sound", r.get("ok") and all(l > -40 for l in levels), "voice / sponsor / voice: " + " / ".join(f"{l:.0f} dB" for l in levels))

        # playback through the switch
        ctl("seek", "time=6.5"); ctl("play"); time.sleep(4)
        t = ctl("status").get("time", 0); ctl("play")
        check("playback", t > 9.5, f"playhead {t:.1f} s after 4 s from 6.5 s")

        # transform + zoom keyframes
        r = ctl("open", f"path={p_anim}")
        a, b = os.path.join(OUT, "k0.png"), os.path.join(OUT, "k1.png")
        ctl("render_frame", "time=3.05", f"out={a}"); ctl("render_frame", "time=5.5", f"out={b}")
        corner_a, corner_b = gray(a, 60, 60), gray(b, 60, 60)
        check("transform", corner_a > 25 and corner_b < 10, f"corner brightness start {corner_a}, end {corner_b} (shrunk = black corner)")
        z = os.path.join(OUT, "z.png")
        r = ctl("render_frame", "time=16.9", f"out={z}")
        check("zoom", r.get("ok") is True and os.path.exists(z), "")

        # switching projects with a clip selected and its Effects panel open (crashed on 2026-11-15)
        empty = project("empty", [])
        ctl("open", f"path={p_main}"); ctl("select", "clip=c2", "ids=c2"); ctl("inspector_tab", "tab=clip"); time.sleep(1)
        ctl("open", f"path={empty}"); time.sleep(1.5); ctl("open", f"path={p_main}"); time.sleep(1)
        alive = ctl("status").get("ok") is True
        check("tab switch", alive, "still running after switching projects" if alive else "Cutgenie stopped")
        if not alive:
            start()
        # blur area: the middle of the picture is hidden, the corners stay as they were
        ctl("open", f"path={p_main}")
        b0, b1 = os.path.join(OUT, "bl0.png"), os.path.join(OUT, "bl1.png")
        ctl("seek", "time=1"); ctl("render_frame", "time=1", f"out={b0}")
        r = ctl("add_shape", "kind=blur", "at=0", "dur=3")
        ctl("render_frame", "time=1", f"out={b1}")
        def psnr(a, b, crop):
            r2 = subprocess.run(["ffmpeg", "-hide_banner", "-i", a, "-i", b, "-lavfi", f"[0]{crop}[x];[1]{crop}[y];[x][y]psnr", "-f", "null", "-"], capture_output=True, text=True)
            for w in r2.stderr.split():
                if w.startswith("average:"):
                    v = w.split(":")[1]; return 99.0 if v == "inf" else float(v)
            return -1
        mid, corner = psnr(b0, b1, "crop=400:100:760:490"), psnr(b0, b1, "crop=200:150:0:0")
        check("blur area", r.get("ok") is True and mid < 35 and corner > 60, f"middle changed (PSNR {mid:.0f} dB), corner untouched ({corner:.0f} dB)")
        ctl("undo")
        # speed: split + undo on a long real project (200+ clips, 300+ graphics) stays quick
        big = BIG
        if big and os.path.exists(big):
            cp = os.path.join(PROJ, "_check_speed.cutgenie.json"); shutil.copy(big, cp)
            ctl("open", f"path={cp}"); time.sleep(8)          # let thumbnails and waveforms finish loading first
            ctl("split", "at=90.5"); ctl("undo")          # warm-up: the first edit after opening loads the files
            open(TIMING, "w").close()
            times = []
            mids = sorted(c["offset"] + c["duration"] / 2 for c in json.load(open(cp))["clips"] if c["duration"] > 1)[20:28]
            for m in mids:          # the middle of a clip: always a real cut (never on an existing cut)
                for args in (("split", f"at={m:.3f}"), ("undo",)):
                    t0 = time.time(); ctl(*args); times.append(time.time() - t0)
            # Cutgenie's own time for each edit (its timing log), not the stopwatch from outside: a background window is
            # scheduled unevenly by macOS, which doubled the outside numbers at random
            own = [float(l.split("total")[1].split("ms")[0]) / 1000 for l in open(TIMING) if l.startswith(("split total", "undo total"))]
            times = own or times
            per = sorted(times)[len(times) // 2]        # middle value: one slow moment (other apps) does not decide it
            check("speed", per < 0.20, f"{per * 1000:.0f} ms per edit (middle of {len(times)}) on a {ctl('status').get('clips', 0)}-clip timeline (limit 200)")
        # autosave: change, crash, reopen -> unsaved work offered
        ctl("open", f"path={p_main}")
        ctl("split", "at=1.5")
        ctl("autosave_now")
        stop(hard=True); start()
        r = ctl("open", f"path={p_main}")
        offer = ctl("autosave_now").get("offer", 0)
        ctl("discard_recovery")
        check("autosave", offer > 0, "recovery offered after a crash" if offer else "no recovery found")
    finally:
        stop()
        for f in os.listdir(PROJ):
            if f.startswith("_check_") or f.startswith("._check_"):
                os.remove(os.path.join(PROJ, f))
    fails = [r for r in results if not r[1]]
    print(f"\n{len(results) - len(fails)} of {len(results)} checks passed" + (f" - FAILED: {', '.join(r[0] for r in fails)}" if fails else ""))
    shutil.rmtree(OUT, ignore_errors=True)
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
