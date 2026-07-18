#!/usr/bin/env python3
"""Generate app/ios/Assets-visionos.xcassets/AppIcon.solidimagestack from the
fork's existing 1024x1024 iOS icon art.

WHY THIS EXISTS. visionOS app icons are LAYERED (.solidimagestack): the system
composites 2-3 square layers with parallax as the user's gaze moves. A flat PNG
in an .appiconset — which is all the fork ships — produces a BLANK tile on
visionOS (recorded as deferred in M-15 known-open #5 and QUESTIONS Q-008).

WHY IT IS A SCRIPT AND NOT HAND-DRAWN LAYERS. The source art is a single flat
render: Mario/Luigi/Wario/Waluigi caps and a Toad mushroom over a yellow-orange
gradient. There is no layered original to go back to. The two honest options
were (a) the vkQuake-ios approach — Back = the whole flat icon, Middle/Front =
transparent — which renders but has zero parallax and is really just "not
blank"; or (b) actually separating subject from background, which is what this
does and what makes the icon look native.

HOW THE SEPARATION WORKS (and why it is safe). The background is a pure
analytic gradient: R==255 and B==0 everywhere, with only G varying (182 at the
TL/BR corners to 254 at TR/BL — measured, not assumed). So:

  1. Mask "background-like" pixels: R>=245, B<=20, G>=170.
  2. Flood fill that mask from the border. This is the load-bearing step: a
     plain threshold would also match the YELLOW parts of the subject (Waluigi's
     'L' logo is near-pure yellow and would be punched out, leaving a hole in
     the letter). Those pixels are enclosed by the purple cap, so a fill that
     can only enter from the border cannot reach them.
  3. Front layer = the art with alpha=0 where the fill reached.
  4. Back layer = the gradient re-synthesised across the WHOLE tile by
     least-squares fitting G over the real background pixels, so nothing shows
     through behind the subject when the layers separate under parallax.

Back must be fully opaque (Apple requires it); Front carries the alpha.

Run: python3 scripts/gen-vision-icon.py
"""
import json
import pathlib

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = ROOT / "vendor/sm64coopdx/platform/ios/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
OUT = ROOT / "app/ios/Assets-visionos.xcassets"
STACK = OUT / "AppIcon.solidimagestack"

BG_R_MIN, BG_B_MAX, BG_G_MIN = 245, 20, 170


def build_masks(img):
    a = np.asarray(img).astype(np.int16)
    R, G, B = a[:, :, 0], a[:, :, 1], a[:, :, 2]
    bg_like = (R >= BG_R_MIN) & (B <= BG_B_MAX) & (G >= BG_G_MIN)

    # Flood fill the background-like mask inward from the border. PIL's fill is
    # C-implemented; 1 = candidate, 0 = subject, 2 = proven background.
    #
    # The .copy() is load-bearing and cost a debugging round: on Pillow 12.3.0
    # ImageDraw.floodfill SILENTLY DOES NOTHING on an Image.fromarray()-backed
    # image (the numpy buffer is read-only, and floodfill neither raises nor
    # reports). Verified by minimal repro: fromarray-backed -> 0 px filled;
    # .copy()-backed and Image.new-backed -> filled correctly. Without the copy
    # this script produces a fully transparent Front layer and a plain gradient
    # tile — i.e. a plausible-looking icon that is quietly wrong.
    m = Image.fromarray(np.where(bg_like, 1, 0).astype(np.uint8), mode="L").copy()
    h, w = bg_like.shape
    seeds = [(0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1), (w // 2, 0), (w // 2, h - 1), (0, h // 2), (w - 1, h // 2)]
    for s in seeds:
        if m.getpixel(s) == 1:
            ImageDraw.floodfill(m, s, 2)
    filled = np.asarray(m) == 2

    n_holes = int((bg_like & ~filled).sum())
    print(f"  bg-like px      : {bg_like.sum():>8}  ({bg_like.mean()*100:.1f}%)")
    print(f"  border-connected: {filled.sum():>8}  ({filled.mean()*100:.1f}%)  <- the real background")
    print(f"  yellow px INSIDE the subject, correctly kept: {n_holes}"
          f"  <- these are what a plain threshold would have punched out")
    return filled


def synth_background(img, bg_mask):
    """Least-squares quadratic fit of G over real background pixels, evaluated
    over the whole tile. R/B are constant (255/0) so only G needs fitting."""
    a = np.asarray(img).astype(np.float64)
    h, w, _ = a.shape
    yy, xx = np.mgrid[0:h, 0:w]
    x = (xx / (w - 1)).ravel()
    y = (yy / (h - 1)).ravel()
    A = np.stack([np.ones_like(x), x, y, x * x, y * y, x * y], axis=1)
    sel = bg_mask.ravel()
    coef, *_ = np.linalg.lstsq(A[sel], a[:, :, 1].ravel()[sel], rcond=None)
    g = np.clip(A @ coef, 0, 255).reshape(h, w)

    resid = np.abs(g.ravel()[sel] - a[:, :, 1].ravel()[sel])
    print(f"  gradient fit residual on real bg px: mean={resid.mean():.2f} max={resid.max():.2f} (0-255 scale)")

    out = np.zeros((h, w, 3), dtype=np.uint8)
    out[:, :, 0] = 255
    out[:, :, 1] = g.astype(np.uint8)
    out[:, :, 2] = 0
    return Image.fromarray(out, mode="RGB")  # opaque: Apple requires it of Back


def front_layer(img, bg_mask):
    rgba = img.convert("RGBA")
    a = np.asarray(rgba).copy()
    alpha = np.where(bg_mask, 0, 255).astype(np.uint8)
    # Feather by a hair: the fill leaves a 1px aliased fringe of near-background
    # pixels along every silhouette, which reads as a hard jaggy edge when the
    # layer floats above the background under parallax.
    alpha = np.asarray(Image.fromarray(alpha, mode="L").filter(ImageFilter.GaussianBlur(0.8)))
    a[:, :, 3] = alpha
    return Image.fromarray(a, mode="RGBA")


def write_layer(name, img, filename):
    d = STACK / f"{name}.solidimagestacklayer"
    (d / "Content.imageset").mkdir(parents=True, exist_ok=True)
    (d / "Contents.json").write_text(json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2) + "\n")
    (d / "Content.imageset" / "Contents.json").write_text(
        json.dumps({"images": [{"idiom": "vision", "scale": "2x", "filename": filename}],
                    "info": {"author": "xcode", "version": 1}}, indent=2) + "\n")
    img.save(d / "Content.imageset" / filename)


def main():
    assert SRC.is_file(), f"source icon missing: {SRC}"
    img = Image.open(SRC).convert("RGB")
    assert img.size == (1024, 1024), f"expected 1024x1024, got {img.size}"
    print(f"source: {SRC.relative_to(ROOT)} {img.size[0]}x{img.size[1]}")

    bg = build_masks(img)
    back = synth_background(img, bg)
    front = front_layer(img, bg)

    STACK.mkdir(parents=True, exist_ok=True)
    (OUT / "Contents.json").write_text(
        json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2) + "\n")
    (STACK / "Contents.json").write_text(json.dumps({
        "info": {"author": "xcode", "version": 1},
        "layers": [{"filename": "Front.solidimagestacklayer"},
                   {"filename": "Middle.solidimagestacklayer"},
                   {"filename": "Back.solidimagestacklayer"}],
    }, indent=2) + "\n")

    write_layer("Back", back, "back.png")
    # Middle is intentionally empty: the source art has exactly two separable
    # planes (subject, background). Inventing a third would mean splitting the
    # cap pile arbitrarily, which would look worse, not better. The layer must
    # still exist — the stack declares three.
    write_layer("Middle", Image.new("RGBA", (1024, 1024), (0, 0, 0, 0)), "clear.png")
    write_layer("Front", front, "front.png")

    # Flatten the layers the way the system composites them at rest, purely so a
    # human can eyeball the result without a headset.
    preview = back.convert("RGBA")
    preview.alpha_composite(front)
    (ROOT / "artifacts").mkdir(exist_ok=True)
    preview.convert("RGB").save(ROOT / "artifacts/p1-icon-composite-preview.png")
    print(f"wrote {STACK.relative_to(ROOT)} (Back opaque, Middle clear, Front alpha)")
    print("preview: artifacts/p1-icon-composite-preview.png")


if __name__ == "__main__":
    main()
