#!/usr/bin/env python3
"""Slim README GIFs: uniform 128-color palette + optimize (optional resize)."""
import sys
from PIL import Image

def slim(src, dst, colors=128, width=None):
    im = Image.open(src)
    frames, durations = [], []
    # build one global palette from a middle frame to avoid per-frame flicker
    im.seek(im.n_frames // 2)
    palette_img = im.convert("RGB").quantize(colors=colors, method=Image.MEDIANCUT)
    im.seek(0)
    for i in range(im.n_frames):
        im.seek(i)
        f = im.convert("RGB")
        if width and f.width != width:
            f = f.resize((width, int(f.height * width / f.width)), Image.LANCZOS)
        frames.append(f.quantize(palette=palette_img, dither=Image.FLOYDSTEINBERG))
        durations.append(im.info.get("duration", 110))
    frames[0].save(dst, save_all=True, append_images=frames[1:],
                   duration=durations, loop=0, optimize=True, disposal=1)
    import os
    print(f"{src}: {os.path.getsize(src)//1024}KB -> {dst}: {os.path.getsize(dst)//1024}KB "
          f"({im.n_frames} frames)")

slim("docs/feeding.gif", "/tmp/feeding_slim.gif")
slim("docs/autopilot.gif", "/tmp/autopilot_slim.gif")
