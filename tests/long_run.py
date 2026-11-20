#!/usr/bin/env python3
"""Long editing session: is Cutzonical still smooth and lean after a long time?

Runs a separate Cutzonical on port 7879 with a copy of a real project (CUTZONICAL_LONG_PROJECT: a copy of one of your projects, with full media paths),
then for N minutes does what an editor does: jump around, play, split + undo, change a clip + undo, switch projects.
Every minute it writes memory use and how long commands take. Fails when memory keeps growing or commands slow down.
Usage:  python3 tests/long_run.py [minutes]     (default 10)
Nothing outside projects/_*.cutzonical.json is touched.
"""
import json, os, random, subprocess, sys, tempfile, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BIN = os.path.join(ROOT, ".build/release/Cutzonical")
CTL = os.path.join(ROOT, "build/cutzonicalctl")
PROJ = os.environ.get("CUTZONICAL_LONG_PROJECT", "")
OTHER = os.path.join(tempfile.gettempdir(), "cutzonical-long-other.cutzonical.json")
env = dict(os.environ, CUTZONICAL_PORT="7879", CUTZONICAL_AWAKE="1")
MIN = float(sys.argv[1]) if len(sys.argv) > 1 else 10


def ctl(*a, timeout=120):
    t = time.time()
    r = subprocess.run([CTL, *a], env=env, capture_output=True, text=True, timeout=timeout)
    try:
        j = json.loads(r.stdout)
    except Exception:
        j = {"ok": False, "error": (r.stdout + r.stderr).strip()}
    return j, time.time() - t


def rss_mb(pid):
    r = subprocess.run(["ps", "-o", "rss=", "-p", str(pid)], capture_output=True, text=True)
    return int(r.stdout.strip() or 0) / 1024


if not PROJ or not os.path.exists(PROJ):
    sys.exit("set CUTZONICAL_LONG_PROJECT to a COPY of one of your projects (full media paths), see docs/TESTING.md")
os.makedirs(os.path.dirname(OTHER), exist_ok=True)
if not os.path.exists(OTHER):     # a small second project to switch to: the first 5 clips of the same one
    p0 = json.load(open(PROJ)); p0["clips"] = p0["clips"][:5]; p0["overlays"] = []; p0["upperClips"] = []; p0["audioClips"] = []
    json.dump(p0, open(OTHER, "w"))
p = subprocess.Popen([BIN], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
for _ in range(60):
    if ctl("status")[0].get("ok"): break
    time.sleep(1)
j, _ = ctl("open", f"path={PROJ}")
dur = j.get("duration", 600)
clips = [c["id"] for c in json.load(open(PROJ))["clips"]]
start = time.time(); samples = []; errors = []; slow = []; n = 0; last_min = -1
random.seed(7)
try:
    while time.time() - start < MIN * 60:
        k = random.random(); t = random.uniform(5, dur - 5)
        if k < 0.35:
            r, s = ctl("seek", f"time={t:.2f}")
        elif k < 0.55:
            ctl("seek", f"time={t:.2f}"); ctl("play"); time.sleep(2.5); r, s = ctl("pause")
        elif k < 0.75:
            r, s = ctl("split", f"at={t:.2f}")
            if r.get("ok"): ctl("undo")
        elif k < 0.92:
            c = random.choice(clips)
            r, s = ctl("set_audio", f"clip={c}", "gain_db=2")
            if r.get("ok"): ctl("undo")
        else:
            ctl("open", f"path={OTHER}"); r, s = ctl("open", f"path={PROJ}")
        n += 1
        if not r.get("ok") and "no clip spans" not in str(r.get("error")) and "unknown command" not in str(r.get("error")):
            errors.append(str(r.get("error"))[:120])
        if s > 3: slow.append(round(s, 1))
        m = int((time.time() - start) / 60)
        if m != last_min:
            last_min = m; mb = rss_mb(p.pid); samples.append(mb)
            st, ss = ctl("status")
            print(f"{m:3d} min  memory {mb:7.0f} MB  status {ss*1000:5.0f} ms  actions {n}", flush=True)
finally:
    p.terminate()
    try: p.wait(10)
    except Exception: p.kill()

warm = samples[1] if len(samples) > 1 else samples[0]
growth = (samples[-1] - warm) / max(1, warm)
ok = growth < 0.5 and not errors and len(slow) < max(3, n // 100)
print(f"\n{'PASS' if ok else 'FAIL'}  {n} actions in {MIN:.0f} min · memory {warm:.0f} -> {samples[-1]:.0f} MB ({growth*100:+.0f} %) · "
      f"{len(errors)} errors · {len(slow)} slow (>3 s)")
for e in sorted(set(errors))[:8]: print("  error:", e)
if slow: print("  slow:", slow[:12])
sys.exit(0 if ok else 1)
