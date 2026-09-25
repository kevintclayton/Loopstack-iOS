"""iPad App Store screenshots (13", 2064x2752), same style as the iPhone set."""
from PIL import Image, ImageDraw, ImageFont
W, H = 2064, 2752
BG = (9, 10, 12); FG = (232, 230, 225); MUTED = (139, 142, 150); LINE = (40, 44, 54); RECORD = (196, 84, 74)
AV = "/System/Library/Fonts/Supplemental/Avenir Next.ttc"
names = {i: ImageFont.truetype(AV, 20, index=i).getname()[1] for i in range(12)}
bold = next(i for i, n in names.items() if n == "Bold")
medium = next(i for i, n in names.items() if n == "Medium")
shots = [
    ("chords", "Your studio,\nnow on iPad", "Play the pads or plug in a MIDI keyboard"),
    ("synth", "Deep FM bass,\nshaped by ear", "FM, filter, drift, tape and wear"),
    ("drums", "Worn-out tape\non the drums", "Tape, Wear, Pitch, Comp, Vinyl and more"),
    ("neon", "Seven kits,\n30 grooves", "From dusty samplers to gated 80s drums"),
    ("song", "Arrange\na song", "Send stacks to the song, then export"),
]
for n, (scene, title, sub) in enumerate(shots, 1):
    c = Image.new("RGB", (W, H), BG); d = ImageDraw.Draw(c)
    d.rounded_rectangle([140, 150, 152, 262], radius=6, fill=RECORD)
    d.multiline_text((190, 120), title, font=ImageFont.truetype(AV, 150, index=bold), fill=FG, spacing=20)
    d.text((194, 120 + 2 * 150 + 20 + 60), sub, font=ImageFont.truetype(AV, 64, index=medium), fill=MUTED)
    raw = Image.open(f"shots-ipad/raw-{scene}.png").convert("RGB")
    raw = raw.crop((0, 90, raw.width, raw.height))
    sw = 1860; sh = int(raw.height * sw / raw.width)
    raw = raw.resize((sw, sh), Image.LANCZOS)
    top, x0 = 700, (W - sw) // 2
    mask = Image.new("L", (sw, sh), 0); ImageDraw.Draw(mask).rounded_rectangle([0, 0, sw - 1, sh + 200], radius=72, fill=255)
    frame = Image.new("RGB", (sw + 8, sh + 8), LINE)
    fm = Image.new("L", (sw + 8, sh + 8), 0); ImageDraw.Draw(fm).rounded_rectangle([0, 0, sw + 7, sh + 300], radius=76, fill=255)
    c.paste(frame, (x0 - 4, top - 4), fm); c.paste(raw, (x0, top), mask)
    c.save(f"appstore-ipad/{n:02d}-{scene}.png"); print("wrote", n, scene)
