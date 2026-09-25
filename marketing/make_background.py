"""Support-page background in the app's look: stacked loop lanes with waveforms, a red
playhead, tape grain; calm and dark in the middle so page text reads on top."""
import numpy as np
from PIL import Image, ImageDraw, ImageFilter
import sys

BG = (9, 10, 12)
FG = (232, 230, 225)
ACCENT = (158, 176, 194)
RECORD = (196, 84, 74)

def render(W, H, seed, out, playhead=0.71):
    rng = np.random.default_rng(seed)
    S = 2  # supersample for smooth capsules
    w, h = W * S, H * S
    base = Image.new("RGB", (w, h), BG)
    layer = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    lane_h = int(h * 0.018)
    gap = int(lane_h * 0.62)
    y = -lane_h // 2
    # how much each point may show: fades toward a calm centre where the text sits
    def calm(x, yy):
        nx = (x / w - 0.5) / 0.5
        ny = (yy / h - 0.5) / 0.5
        r = np.sqrt((nx * 0.95) ** 2 + (ny * 1.25) ** 2)
        return float(np.clip((r - 0.28) / 0.55, 0.12, 1.0))
    while y < h:
        x = -rng.integers(0, w // 6)
        while x < w:
            seg = int(w * rng.uniform(0.12, 0.42))
            if rng.random() < 0.22:  # empty stretch in the lane
                x += seg
                continue
            cx, cy = x + seg / 2, y + lane_h / 2
            vis = calm(cx, cy)
            tone = [ACCENT, FG, ACCENT, ACCENT][rng.integers(0, 4)]
            a = int(255 * vis * rng.uniform(0.10, 0.22))
            d.rounded_rectangle([x, y, x + seg, y + lane_h], radius=lane_h // 2, fill=tone + (a,))
            # waveform inside: repeating hits (it's a loop), decaying envelopes
            period = int(rng.uniform(0.08, 0.2) * seg) or 1
            wa = int(255 * vis * rng.uniform(0.35, 0.6))
            for px in range(int(x + lane_h * 0.5), int(x + seg - lane_h * 0.5), S * 3):
                ph = (px - x) % period / period
                env = np.exp(-ph * rng.uniform(3, 7)) * (0.35 + 0.65 * rng.random())
                hh = max(S, env * lane_h * 0.42)
                d.line([px, cy - hh, px, cy + hh], fill=tone + (wa,), width=S)
            x += seg + int(gap * rng.uniform(0.6, 2.0))
        y += lane_h + gap
    # playhead: a red line through the lanes, with a soft glow
    phx = int(w * playhead)
    glow = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    ImageDraw.Draw(glow).rectangle([phx - 18 * S, 0, phx + 18 * S, h], fill=RECORD + (60,))
    glow = glow.filter(ImageFilter.GaussianBlur(28 * S))
    layer = Image.alpha_composite(glow, layer)
    ImageDraw.Draw(layer).rounded_rectangle([phx - 3 * S, 0, phx + 3 * S, h], radius=3 * S, fill=RECORD + (205,))
    base = Image.alpha_composite(base.convert("RGBA"), layer).convert("RGB")
    base = base.resize((W, H), Image.LANCZOS)
    # vignette + tape grain
    arr = np.asarray(base).astype(np.float32)
    yy, xx = np.mgrid[0:H, 0:W]
    r = np.sqrt(((xx / W - 0.5) * 1.1) ** 2 + ((yy / H - 0.5) * 1.1) ** 2)
    vig = np.clip(1.0 - 0.55 * r ** 1.6, 0.45, 1.0)[..., None]
    arr = BG + (arr - BG) * vig
    arr += rng.normal(0, 3.2, (H, W, 1))
    Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8)).save(out, quality=92, optimize=True)
    print("wrote", out, W, "x", H)

render(2880, 1800, 7, "loopstack-bg-desktop.jpg")
render(1290, 2796, 11, "loopstack-bg-mobile.jpg", playhead=0.88)
