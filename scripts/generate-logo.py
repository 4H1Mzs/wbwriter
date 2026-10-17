import os, subprocess, shutil
# Generates the WBWriter mark, wordmarks, PNG renders and AppIcon.icns into Assets/.
# Needs fontTools (pip install fonttools) and rsvg-convert. Run: python3 scripts/generate-logo.py
from fontTools.ttLib import TTFont
from fontTools.varLib.instancer import instantiateVariableFont
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Assets")
import tempfile
SCR = tempfile.mkdtemp(prefix="wbwriter-icon-")
RSVG = shutil.which("rsvg-convert") or "/opt/local/bin/rsvg-convert"

# ---------- mark ----------
# W: one continuous marker gesture. Slight lean, outer arms taller than middle peak,
# softly rounded valleys, a little exit flick on the right arm.
W_PATH = (
    "M 254 330 "
    "C 296 452, 338 584, 376 686 "        # down-stroke 1, slight bow
    "C 384 708, 402 708, 410 688 "         # valley 1 (deepest)
    "C 440 606, 468 524, 492 458 "         # up to middle peak
    "C 498 442, 514 442, 520 458 "         # peak
    "C 546 530, 572 604, 598 670 "         # down to valley 2 (a touch higher: hand-written)
    "C 606 692, 624 692, 632 672 "         # valley 2
    "C 694 548, 736 420, 774 300"          # right arm sweeps up and out
)

def mark_defs(p=""):
    return f"""
    <linearGradient id="{p}bg" x1="0.2" y1="0" x2="0.5" y2="1">
      <stop offset="0" stop-color="#4E1D80"/>
      <stop offset="0.55" stop-color="#321259"/>
      <stop offset="1" stop-color="#1B0832"/>
    </linearGradient>
    <radialGradient id="{p}glow" cx="0.5" cy="0.08" r="0.75">
      <stop offset="0" stop-color="#9B5CE0" stop-opacity="0.30"/>
      <stop offset="1" stop-color="#9B5CE0" stop-opacity="0"/>
    </radialGradient>
    <linearGradient id="{p}rim" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#FFFFFF" stop-opacity="0.22"/>
      <stop offset="0.5" stop-color="#FFFFFF" stop-opacity="0.04"/>
      <stop offset="1" stop-color="#000000" stop-opacity="0.25"/>
    </linearGradient>
    <linearGradient id="{p}ink" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#FFFFFF"/>
      <stop offset="1" stop-color="#EEE6FA"/>
    </linearGradient>
    <radialGradient id="{p}spark" cx="0.5" cy="0.5" r="0.5">
      <stop offset="0" stop-color="#FFE7FF" stop-opacity="1"/>
      <stop offset="0.35" stop-color="#E58BFF" stop-opacity="0.75"/>
      <stop offset="1" stop-color="#C45CFF" stop-opacity="0"/>
    </radialGradient>
    <filter id="{p}shadow" x="-20%" y="-20%" width="140%" height="150%">
      <feGaussianBlur in="SourceAlpha" stdDeviation="14"/>
      <feOffset dy="12" result="b"/>
      <feComponentTransfer><feFuncA type="linear" slope="0.35"/></feComponentTransfer>
      <feMerge><feMergeNode/><feMergeNode in="SourceGraphic"/></feMerge>
    </filter>
    <filter id="{p}inkglow" x="-30%" y="-30%" width="160%" height="160%">
      <feGaussianBlur stdDeviation="16"/>
    </filter>
    <clipPath id="{p}clip"><rect x="100" y="100" width="824" height="824" rx="185" ry="185"/></clipPath>
"""

def mark_body(p="", shadow=True):
    sh = f' filter="url(#{p}shadow)"' if shadow else ""
    return f"""
  <g{sh}>
    <rect x="100" y="100" width="824" height="824" rx="185" ry="185" fill="url(#{p}bg)"/>
  </g>
  <g clip-path="url(#{p}clip)">
    <rect x="100" y="100" width="824" height="824" fill="url(#{p}glow)"/>
    <!-- LED-ish halo behind the ink -->
    <path d="{W_PATH}" fill="none" stroke="#B57BFF" stroke-opacity="0.45" stroke-width="96"
          stroke-linecap="round" stroke-linejoin="round" filter="url(#{p}inkglow)"/>
    <!-- the marker stroke -->
    <path d="{W_PATH}" fill="none" stroke="url(#{p}ink)" stroke-width="80"
          stroke-linecap="round" stroke-linejoin="round"/>
    <!-- pen spark: a small twinkle just past the stroke end -->
    <circle cx="834" cy="240" r="62" fill="url(#{p}spark)"/>
    <path d="M 834 202 C 838 226, 848 236, 872 240 C 848 244, 838 254, 834 278 C 830 254, 820 244, 796 240 C 820 236, 830 226, 834 202 Z" fill="#FFFFFF"/>
  </g>
  <rect x="101.5" y="101.5" width="821" height="821" rx="183.5" ry="183.5" fill="none"
        stroke="url(#{p}rim)" stroke-width="3"/>
"""

def mark_svg():
    return f"""<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
  <defs>{mark_defs()}</defs>{mark_body()}
</svg>
"""

# ---------- wordmark ----------
def outline_text(text, size, weight=760):
    f = TTFont("/System/Library/Fonts/SFNS.ttf")
    f = instantiateVariableFont(f, {"wght": weight, "opsz": 96, "wdth": 100, "GRAD": 400})
    gs = f.getGlyphSet(); cmap = f.getBestCmap(); upm = f["head"].unitsPerEm
    hmtx = f["hmtx"]
    scale = size / upm
    kern = None
    x = 0; parts = []
    names = [cmap[ord(c)] for c in text]
    for i, n in enumerate(names):
        pen = SVGPathPen(gs)
        tp = TransformPen(pen, (scale, 0, 0, -scale, x, 0))
        gs[n].draw(tp)
        parts.append(pen.getCommands())
        adv = hmtx[n][0] * scale
        x += adv - size * 0.012  # slight tightening for display size
    capH = getattr(f["OS/2"], "sCapHeight", 1400) * scale
    return " ".join(parts), x + size * 0.012, capH

def wordmark_svg(text_color, sub_color):
    # layout: mark scaled from 1024 -> 400 (artwork 100..924 => visible 322px)
    S = 400 / 1024
    H = 400
    txt, tw, capH = outline_text("WBWriter", 220)
    tx = 400 + 4
    ty = H / 2 + capH / 2 - 4
    W = int(tx + tw + 60)
    return f"""<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}">
  <defs>{mark_defs("m")}</defs>
  <g transform="scale({S})">{mark_body("m")}</g>
  <path transform="translate({tx:.2f},{ty:.2f})" fill="{text_color}" d="{txt}"/>
</svg>
"""

def write(name, s):
    with open(os.path.join(OUT, name), "w") as fh: fh.write(s)

write("logo-mark.svg", mark_svg())
write("logo-wordmark.svg", wordmark_svg("#2A0F4A", "#4B1C7A"))
write("logo-wordmark-dark.svg", wordmark_svg("#FFFFFF", "#CDB8EE"))

def render(svg, png, w=None, h=None):
    cmd = [RSVG, "-o", png]
    if w: cmd += ["-w", str(w)]
    if h: cmd += ["-h", str(h)]
    subprocess.check_call(cmd + [svg])

render(f"{OUT}/logo-mark.svg", f"{OUT}/logo-mark-1024.png", 1024, 1024)
render(f"{OUT}/logo-wordmark.svg", f"{OUT}/logo-wordmark.png", 1600)
render(f"{OUT}/logo-wordmark-dark.svg", f"{OUT}/logo-wordmark-dark.png", 1600)

iconset = os.path.join(SCR, "AppIcon.iconset")
shutil.rmtree(iconset, ignore_errors=True); os.makedirs(iconset)
for s in (16, 32, 128, 256, 512):
    render(f"{OUT}/logo-mark.svg", f"{iconset}/icon_{s}x{s}.png", s, s)
    render(f"{OUT}/logo-mark.svg", f"{iconset}/icon_{s}x{s}@2x.png", 2*s, 2*s)
subprocess.check_call(["iconutil", "-c", "icns", iconset, "-o", f"{OUT}/AppIcon.icns"])
print("ok")
