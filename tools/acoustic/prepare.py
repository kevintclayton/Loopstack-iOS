#!/usr/bin/env python3
"""Builds Loopstack's acoustic instruments from the Versilian libraries (VCSL and
VSCO 2 Community Edition, both CC0 / public domain).

For each instrument: download every note and velocity layer (first take only), measure
each note's real pitch, trim the start, cut decaying sounds to length with a fade or give
sustained sounds a seamless crossfaded loop, level the instrument as a whole (so soft and
loud layers keep their natural difference), and write compressed files plus a manifest.

Output: Loopstack/Samples/Instruments/<id>/ (audio) and manifest.json per instrument.
Usage: python3 tools/acoustic/prepare.py [instrument ids...]
"""
import json, os, re, subprocess, sys, urllib.parse, urllib.request, wave
import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = os.path.join(ROOT, "Loopstack", "Samples", "Instruments")
CACHE = os.environ.get("ACOUSTIC_CACHE", "/tmp/loopstack-acoustic-cache")
SR = 44100
REPOS = {"vcsl": "sgossner/VCSL", "vsco": "sgossner/VSCO-2-CE"}

# (repo, folder, filename filter). Velocity layers come from the file names.
INSTRUMENTS = {
    "upright":     dict(name="Upright Piano", parts=[("vsco", "Keys/Upright Piano", r"_rr1_", None, (21, 2))], length=6.0, release=0.35),
    "grand":       dict(name="Grand Piano", parts=[("vcsl", "Chordophones/Zithers/Grand Piano, Steinway B/Sus", r"_rr1")], length=6.0, release=0.35),
    "harpsichord": dict(name="Harpsichord", parts=[("vcsl", "Chordophones/Zithers/Harpsichord, French/Sustains", r"_rr1")], length=4.0, release=0.2),
    "organ":       dict(name="Organ", parts=[("vsco", "Keys/Organ/Quiet", r"_rr1")], loop=True, release=0.25),
    "strings":     dict(name="Strings", parts=[("vsco", "Strings/Violin Section/susVib", r""),
                                              ("vsco", "Strings/Viola Section/susvib", r"", 55),
                                              ("vsco", "Strings/Cello Section/susvib", r"", 48)], loop=True, release=0.45),
    "cello":       dict(name="Cello", parts=[("vsco", "Strings/Cello Section/susvib", r"")], loop=True, release=0.4),
    "pizzicato":   dict(name="Pizzicato", parts=[("vsco", "Strings/Violin Section/Pizz", r"_rr1"),
                                                ("vsco", "Strings/Cello Section/pizzT", r"_RR1", 55)], length=2.0, release=0.12),
    "harp":        dict(name="Harp", parts=[("vsco", "Strings/Harp", r"")], length=4.5, release=0.5),
    "flute":       dict(name="Flute", parts=[("vsco", "Woodwinds/Flute/susNV", r"")], loop=True, release=0.25),
    "clarinet":    dict(name="Clarinet", parts=[("vsco", "Woodwinds/Clarinet/susLong", r"_rr1")], loop=True, release=0.2),
    "sax":         dict(name="Tenor Sax", parts=[("vcsl", "Aerophones/Reed Aerophones/Tenor Saxophone/Non-Vibrato", r"_rr1")], loop=True, release=0.2),
    "horn":        dict(name="French Horn", parts=[("vsco", "Brass/F Horn/sus", r"")], loop=True, release=0.3),
    "vibraphone":  dict(name="Vibraphone", parts=[("vcsl", "Idiophones/Struck Idiophones/Vibraphone/Soft Mallets", r"_rr1_")], length=5.0, release=0.4),
    "marimba":     dict(name="Marimba", parts=[("vcsl", "Idiophones/Struck Idiophones/Marimba", r"_01")], length=2.5, release=0.15),
    "glockenspiel": dict(name="Glockenspiel", parts=[("vcsl", "Idiophones/Struck Idiophones/Glockenspiel", r"_01")], length=3.0, release=0.3),
    "kalimba":     dict(name="Kalimba", parts=[("vcsl", "Idiophones/Plucked Idiophones/Kalimba, Kenya", r"")], length=3.0, release=0.25),
}

NOTE_RE = re.compile(r"(?:^|[_\-\s])([A-G])(#|b)?(-?\d)(?=[_\-\s.]|$)")
VEL_PATTERNS = [(re.compile(r"_vl?(\d)"), None), (re.compile(r"dyn(\d)"), None)]
VEL_WORDS = {"pp": 1, "p": 2, "soft": 1, "mp": 2, "med": 2, "medium": 2, "mf": 3, "f": 4, "loud": 4, "ff": 5}


def tree(repo):
    path = os.path.join(CACHE, f"{repo}-tree.json")
    if not os.path.exists(path):
        os.makedirs(CACHE, exist_ok=True)
        url = f"https://api.github.com/repos/{REPOS[repo]}/git/trees/master?recursive=1"
        urllib.request.urlretrieve(url, path)
    return json.load(open(path))["tree"]


def fetch(repo, path):
    local = os.path.join(CACHE, repo, path.replace("/", "__"))
    if not os.path.exists(local):
        os.makedirs(os.path.dirname(local), exist_ok=True)
        url = f"https://raw.githubusercontent.com/{REPOS[repo]}/master/" + urllib.parse.quote(path)
        urllib.request.urlretrieve(url, local)
    return local


def load_mono(path):
    tmp = path + ".mono.wav"
    if not os.path.exists(tmp):
        subprocess.run(["afconvert", "-f", "WAVE", "-d", f"LEI16@{SR}", "-c", "1", path, tmp], check=True)
    w = wave.open(tmp)
    x = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(np.float64) / 32768
    return x


def name_note(fname):
    m = NOTE_RE.search(os.path.splitext(fname)[0])
    if not m:
        return None
    pc = "C C# D D# E F F# G G# A A# B".split().index(m.group(1) + ("#" if m.group(2) == "#" else ""))
    if m.group(2) == "b":
        pc -= 1
    return (int(m.group(3)) + 1) * 12 + pc  # C4 = 60


def velocity_rank(fname):
    base = os.path.splitext(fname)[0]
    for rx, _ in VEL_PATTERNS:
        m = rx.search(base)
        if m:
            return int(m.group(1))
    for tok in re.split(r"[_\-\s]", base.lower()):
        if tok in VEL_WORDS:
            return VEL_WORDS[tok]
    return 1


def detect_midi(x):
    """YIN-style fundamental over a steady stretch after the attack."""
    onset = first_sound(x)
    seg = x[onset + int(0.12 * SR): onset + int(0.12 * SR) + 8192]
    if len(seg) < 4096:
        seg = x[onset: onset + 8192]
    seg = seg - seg.mean()
    n = len(seg) // 2
    lo, hi = int(SR / 4200), int(SR / 25)
    d = np.array([np.sum((seg[:n] - seg[t:t + n]) ** 2) for t in range(hi + 1)])
    cmnd = d.copy()
    cmnd[1:] = d[1:] * np.arange(1, hi + 1) / np.maximum(np.cumsum(d[1:]), 1e-12)
    cmnd[0] = 1
    cand = [t for t in range(lo, hi) if cmnd[t] < 0.15 and cmnd[t] <= cmnd[t - 1] and cmnd[t] <= cmnd[t + 1]]
    t = cand[0] if cand else lo + int(np.argmin(cmnd[lo:hi]))
    if 1 <= t < hi:  # parabolic refinement
        a, b, c = cmnd[t - 1], cmnd[t], cmnd[t + 1]
        t = t + 0.5 * (a - c) / max(a - 2 * b + c, 1e-12)
    f = SR / t
    return 69 + 12 * np.log2(f / 440.0), f


def first_sound(x, thresh=0.002):
    peak = np.max(np.abs(x)) or 1
    idx = np.nonzero(np.abs(x) > max(thresh, peak * 0.01))[0]
    return max(0, int(idx[0]) - 64) if len(idx) else 0


def find_loop(x):
    """A long loop late in the sustain whose ends match, joined with a smooth equal-power
    crossfade. Long loops (up to ~2.5 s) and a long seam hide ensemble vibrato, which never
    repeats exactly; the correlation picks the start where the waveform best continues."""
    n = len(x)
    end = min(n - int(0.08 * SR), int(4.2 * SR))
    if end < int(1.6 * SR):
        return None
    w = 2048
    ref = x[end - w:end]
    best, best_s = -2, None
    lo, hi = max(int(0.5 * SR) + w, end - int(2.5 * SR)), end - int(0.9 * SR)
    for s in range(lo, hi, 5):
        cand = x[s - w:s]
        c = np.dot(ref, cand) / (np.linalg.norm(ref) * np.linalg.norm(cand) + 1e-12)
        if c > best:
            best, best_s = c, s
    s = best_s
    L = min(int(0.18 * SR), (end - s) // 3)
    y = x[:end].copy()
    g = np.linspace(0, 1, L)
    fade_in, fade_out = np.sqrt(g), np.sqrt(1 - g)
    y[end - L:end] = x[end - L:end] * fade_out + x[s - L:s] * fade_in
    return y, s, end, best


def build(iid, spec):
    out_dir = os.path.join(OUT, iid)
    os.makedirs(out_dir, exist_ok=True)
    zones, report = [], []
    for part in spec["parts"]:
        repo, folder, rx = part[0], part[1], part[2]
        below = part[3] if len(part) > 3 else None  # this part only covers roots below this note
        numbering = part[4] if len(part) > 4 else None  # numbered files: root = a + b * number
        files = sorted(t["path"] for t in tree(repo) if t["type"] == "blob" and t["path"].startswith(folder + "/")
                       and t["path"].count("/") == folder.count("/") + 1 and t["path"].lower().endswith(".wav")
                       and re.search(rx, os.path.basename(t["path"])))
        loaded = []
        for p in files:
            x = load_mono(fetch(repo, p))
            midi_f, hz = detect_midi(x)
            named = name_note(os.path.basename(p))
            if numbering:
                num = int(re.findall(r"(\d+)", os.path.splitext(os.path.basename(p))[0])[-1])
                named = numbering[0] + numbering[1] * num
            loaded.append((p, x, midi_f, hz, named))
        # Libraries differ in octave naming (some call 440 Hz "A3"): the part's offset
        # is the median measured-minus-named difference, rounded to whole octaves.
        diffs = [m - n for _, _, m, _, n in loaded if n is not None]
        offset = 0 if numbering else (int(round(np.median(diffs) / 12)) * 12 if diffs else 0)
        for p, x, midi_f, hz, named in loaded:
            if named is not None:
                root = named + offset
                off = midi_f - root
                if abs(off - round(off / 12) * 12) > 0.6:
                    # The name wins (detectors slip on very short or very low notes); flag it.
                    report.append(f"   measured {hz:.1f} Hz (midi {midi_f:.2f}) vs name {root}: {os.path.basename(p)}")
            else:
                root = int(round(midi_f))
            if below is not None and root >= below:
                continue
            # Fine tuning from the measurement when it agrees with the note (within 60 cents).
            fine = (midi_f - root) - round((midi_f - root) / 12) * 12
            cents = round(fine * 100, 1) if (named is None or abs(fine) <= 0.6) else 0.0
            zones.append(dict(src=p, root=root, cents=cents,
                              vel=velocity_rank(os.path.basename(p)), x=x))
    if not zones:
        raise SystemExit(f"{iid}: no samples")
    # Instrument-wide level: loudest sample peaks at 0.9.
    peak = max(np.max(np.abs(z["x"])) for z in zones)
    manifest = dict(id=iid, name=spec["name"], release=spec["release"], loop=bool(spec.get("loop")), zones=[])
    ranks = sorted({z["vel"] for z in zones})
    for i, z in enumerate(sorted(zones, key=lambda z: (z["root"], z["vel"]))):
        x = z["x"] * (0.9 / peak)
        x = x[first_sound(x):]
        entry = dict(root=z["root"], cents=z["cents"], layer=ranks.index(z["vel"]), layers=len(ranks))
        if spec.get("loop"):
            res = find_loop(x)
            if res is None:
                continue
            y, s, e, corr = res
            entry.update(loopStart=int(s), loopEnd=int(e), loopMatch=round(float(corr), 3))
            fname = f"{i:03d}.caf"
            write(y, os.path.join(out_dir, fname), lossless=True)
        else:
            m = min(len(x), int(spec["length"] * SR))
            y = x[:m].copy()
            f = min(int(0.3 * SR), m // 3)
            y[m - f:] *= np.linspace(1, 0, f) ** 2
            fname = f"{i:03d}.m4a"
            write(y, os.path.join(out_dir, fname), lossless=False)
        entry["file"] = fname
        manifest["zones"].append(entry)
    json.dump(manifest, open(os.path.join(out_dir, "manifest.json"), "w"), indent=1)
    size = sum(os.path.getsize(os.path.join(out_dir, f)) for f in os.listdir(out_dir))
    roots = [z["root"] for z in manifest["zones"]]
    print(f"{iid:13s} {len(manifest['zones']):3d} zones, {len(ranks)} velocity layer(s), notes {min(roots)}-{max(roots)}, {size/1e6:5.1f} MB")
    for r in report[:6]:
        print(r)


def write(y, path, lossless):
    tmp = path + ".wav"
    w = wave.open(tmp, "wb")
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR)
    w.writeframes((np.clip(y, -1, 1) * 32767).astype(np.int16).tobytes())
    w.close()
    if lossless:
        subprocess.run(["afconvert", "-f", "caff", "-d", "alac", tmp, path], check=True)
    else:
        subprocess.run(["afconvert", "-f", "m4af", "-d", "aac", "-b", "128000", "-q", "127", tmp, path], check=True)
    os.remove(tmp)


if __name__ == "__main__":
    ids = sys.argv[1:] or list(INSTRUMENTS)
    for iid in ids:
        build(iid, INSTRUMENTS[iid])
