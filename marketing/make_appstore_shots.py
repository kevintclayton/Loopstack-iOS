"""App Store screenshots (6.9", 1320x2868): caption on the app's dark background, the
real screenshot below with rounded corners, status bar cropped off."""
from PIL import Image, ImageDraw, ImageFont
W, H = 1320, 2868
BG = (9, 10, 12); FG = (232, 230, 225); MUTED = (139, 142, 150); LINE = (40, 44, 54); RECORD = (196, 84, 74)
AV = "/System/Library/Fonts/Supplemental/Avenir Next.ttc"
def font(size, idx):
    return ImageFont.truetype(AV, size, index=idx)
# Avenir Next faces: 0 Bold, 2 Demi Bold, 5 Medium, 7 Regular (index order in the .ttc)
names = {i: ImageFont.truetype(AV, 20, index=i).getname()[1] for i in range(12)}
bold = next(i for i, n in names.items() if n == "Bold")
medium = next(i for i, n in names.items() if n == "Medium")
shots = [
    ("stack", "Your pocket\nmusic studio", "Loops, synths and drums in one stack"),
    ("keys", "Play in key,\nevery time", "Latch the arp and build long patterns"),
    ("chords", "One tap,\nfull chords", "Triads and 7ths in any key"),
    ("synth", "Deep FM bass,\nshaped by ear", "FM, filter, drift, tape and wear"),
    ("loops", "Stack up\nto 8 loops", "Every take is a full pass, on the beat"),
    ("reverse", "Flip it, slow it,\ndrive it", "Reverse, half speed and drive per loop"),
    ("drums", "Worn-out tape\non the drums", "Tape, Wear, Pitch, Comp, Vinyl and more"),
    ("neon", "Seven kits,\n30 grooves", "From dusty samplers to gated 80s drums"),
    ("mix", "Mix it\nyour way", "Keys, loops, drums and master"),
    ("song", "Arrange\na song", "Send stacks to the song, then export"),
]
for n, (scene, title, sub) in enumerate(shots, 1):
    canvas = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(canvas)
    # small red playhead mark, like the logo, above the caption
    d.rounded_rectangle([96, 190, 104, 262], radius=4, fill=RECORD)
    ft = font(118, bold)
    d.multiline_text((130, 170), title, font=ft, fill=FG, spacing=18)
    d.text((132, 170 + 2 * 118 + 18 + 44), sub, font=font(50, medium), fill=MUTED)
    # the screenshot: status bar off, scaled, rounded, bleeding off the bottom
    raw = Image.open(f"shots/raw-{scene}.png").convert("RGB")
    raw = raw.crop((0, 190, raw.width, raw.height))
    sw = 1130
    sh = int(raw.height * sw / raw.width)
    raw = raw.resize((sw, sh), Image.LANCZOS)
    top = 720
    x0 = (W - sw) // 2
    mask = Image.new("L", (sw, sh), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, sw - 1, sh + 200], radius=64, fill=255)
    frame = Image.new("RGB", (sw + 8, sh + 8), LINE)
    fmask = Image.new("L", (sw + 8, sh + 8), 0)
    ImageDraw.Draw(fmask).rounded_rectangle([0, 0, sw + 7, sh + 300], radius=68, fill=255)
    canvas.paste(frame, (x0 - 4, top - 4), fmask)
    canvas.paste(raw, (x0, top), mask)
    out = f"appstore/{n:02d}-{scene}.png"
    canvas.save(out)
    print("wrote", out)
