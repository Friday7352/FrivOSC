#!/usr/bin/env python3
"""Preview the launcher's two icons without a Windows machine.

NOT a test — nothing here asserts anything. FrivOSC-Launcher.ps1 draws the
microphone and chatbox glyphs with GDI+ at run time rather than shipping
images, which means the only way to see them is normally to install the
thing on Windows. This redraws the same coordinates with Pillow so the
proportions can be looked at while they are being changed.

It is a hand port, so it can drift: if you change the geometry in
Draw-FrivoMicIcon or Draw-FrivoChatIcon, change it here too, or this stops
telling you the truth. The shapes are simple enough that this is a fair
trade for being able to iterate at all.

Usage:  python3 tests/preview-icons.py     (writes icons.png beside itself)
Needs:  pillow
"""
import os

from PIL import Image, ImageDraw

S = 6                      # supersample, then downscale for antialiasing
W, H = 40, 38
CARD    = (28, 35, 45)
SURFACE = (22, 27, 34)
SIGNAL  = (62, 207, 109)
WARN    = (240, 166, 60)
FAINT   = (110, 119, 134)

def mic(d, color, muted):
    cx, top = W // 2, 2
    # FillRectangle + two FillEllipse = the capsule
    d.rectangle([s(cx-5), s(top+5), s(cx+5), s(top+13)], fill=color)
    d.ellipse([s(cx-5), s(top), s(cx+5), s(top+10)], fill=color)
    d.ellipse([s(cx-5), s(top+8), s(cx+5), s(top+18)], fill=color)
    # DrawArc(x, y, w, h, 0, 180): GDI+ angles go clockwise from 3 o'clock,
    # so 0->180 is the lower half. PIL's arc matches that convention.
    d.arc([s(cx-9), s(top+6), s(cx+9), s(top+22)], 0, 180, fill=color, width=s(2))
    d.line([s(cx), s(top+22), s(cx), s(top+27)], fill=color, width=s(2))
    d.line([s(cx-6), s(top+27), s(cx+6), s(top+27)], fill=color, width=s(2))
    if muted:
        d.line([s(cx-11), s(top-3), s(cx+11), s(top+26)], fill=SURFACE, width=int(s(4.5)))
        d.line([s(cx-10), s(top-2), s(cx+10), s(top+25)], fill=color, width=s(2))

def chat(d, color, active):
    x, y, w, h, r = 2, 3, W-4, 20, 7
    d.rounded_rectangle([s(x), s(y), s(x+w), s(y+h)], radius=s(r), outline=color, width=s(2))
    d.polygon([(s(x+7), s(y+h-1)), (s(x+7), s(y+h+6)), (s(x+15), s(y+h-1))], fill=color)
    if active:
        dy = y + h//2 - 2
        for off in (-6, 0, 6):
            d.ellipse([s(x+w//2+off-2), s(dy), s(x+w//2+off+2), s(dy+4)], fill=color)
    else:
        my = y + h//2
        d.line([s(x+7), s(my), s(x+w-7), s(my)], fill=color, width=s(2))

def s(v):
    return int(round(v * S))

states = [("mic  live", mic, SIGNAL, False), ("mic  muted", mic, WARN, True),
          ("mic  unknown", mic, FAINT, False),
          ("chat recv", chat, SIGNAL, True), ("chat idle", chat, FAINT, False)]

scale_out = 4
tiles = []
for _name, fn, color, flag in states:
    big = Image.new("RGB", (W*S, H*S), SURFACE)
    fn(ImageDraw.Draw(big), color, flag)
    tiles.append(big.resize((W*scale_out, H*scale_out), Image.LANCZOS))

pad = 20
sheet = Image.new("RGB", (sum(t.width for t in tiles) + pad*(len(tiles)+1),
                          tiles[0].height + pad*2), SURFACE)
x = pad
for t in tiles:
    sheet.paste(t, (x, pad)); x += t.width + pad
out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "icons.png")
sheet.save(out)
print("wrote %s — %s" % (out, "  |  ".join(n for n, *_ in states)))
