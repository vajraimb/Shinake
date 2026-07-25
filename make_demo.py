#!/usr/bin/env python3
"""Assemble a SNAKE_RECORD frame dump into an animated WebP.

    SNAKE_RECORD=/tmp/shinake_rec ./shinake
    python3 make_demo.py /tmp/shinake_rec/frames docs/attract.webp --fps 10

Frames (f0001.png …) are read in lexical order, converted to RGB, optionally
resized, and written with quality/method=6, loop=0, per-frame duration from
fps. Works fully headless. `--selftest` synthesizes 4 frames and verifies the
roundtrip (frame count + dimensions), printing PASS and exiting 0/1.
"""
import argparse
import os
import sys

from PIL import Image


def assemble(frames_dir, out, fps=10, width=512, quality=70):
    files = sorted(f for f in os.listdir(frames_dir) if f.endswith(".png"))
    if not files:
        sys.exit(f"make_demo: no .png frames in {frames_dir}")
    frames = []
    for f in files:
        im = Image.open(os.path.join(frames_dir, f)).convert("RGB")
        if width and im.width != width:
            im = im.resize((width, int(im.height * width / im.width)),
                           Image.LANCZOS)
        frames.append(im)
    duration = round(1000 / fps)
    frames[0].save(out, save_all=True, append_images=frames[1:],
                   duration=duration, loop=0, quality=quality, method=6)
    return len(frames)


def webp_frame_info(path):
    """(frame_count, first-frame duration ms) by scanning ANMF chunks —
    this Pillow build doesn't expose WebP durations via im.info."""
    data = open(path, "rb").read()
    count, dur, pos = 0, None, 0
    while True:
        pos = data.find(b"ANMF", pos)
        if pos < 0:
            break
        count += 1
        if dur is None:
            # ANMF payload: 4x3 bytes frame rect, then 3-byte LE duration
            dur = int.from_bytes(data[pos + 8 + 12:pos + 8 + 15], "little")
        pos += 4
    return count, dur


def selftest():
    import tempfile
    d = tempfile.mkdtemp(prefix="make_demo_")
    colors = [(230, 60, 60), (255, 220, 80), (120, 220, 255), (170, 70, 220)]
    for i, c in enumerate(colors):
        Image.new("RGB", (320, 180), c).save(os.path.join(d, f"f{i + 1:04d}.png"))
    out = os.path.join(d, "selftest.webp")
    n = assemble(d, out, fps=10, width=160, quality=70)
    im = Image.open(out)
    n_anmf, dur = webp_frame_info(out)
    ok = (n == 4 and n_anmf == 4 and dur == 100
          and im.width == 160 and im.height == 90)
    print(f"make_demo selftest: frames={n_anmf} "
          f"size={im.width}x{im.height} duration={dur}ms "
          f"-> {'PASS' if ok else 'FAIL'}")
    sys.exit(0 if ok else 1)


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("frames_dir", nargs="?", help="dir with f0001.png … frames")
    p.add_argument("out", nargs="?", help="output .webp path")
    p.add_argument("--fps", type=float, default=10, help="playback rate (default 10)")
    p.add_argument("--width", type=int, default=512, help="output width px (default 512)")
    p.add_argument("--quality", type=int, default=70, help="webp quality (default 70)")
    p.add_argument("--selftest", action="store_true", help="synthetic roundtrip check")
    a = p.parse_args()
    if a.selftest:
        selftest()
    if not a.frames_dir or not a.out:
        p.error("frames_dir and out are required (or use --selftest)")
    n = assemble(a.frames_dir, a.out, fps=a.fps, width=a.width, quality=a.quality)
    size = os.path.getsize(a.out)
    print(f"{a.out}: {n} frames, {size / 1024:.0f} KB ({size / 1048576:.2f} MB)")


if __name__ == "__main__":
    main()
