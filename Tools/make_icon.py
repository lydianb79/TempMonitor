#!/usr/bin/env python3
"""Generates the TempMonitor app icon: a black macOS squircle with a procedural flame.

Usage: python3 make_icon.py <output-dir>
Writes AppIcon-1024.png, an AppIcon.iconset folder and AppIcon.icns (no iconutil needed).
"""
import os, struct, sys, io
import numpy as np
from PIL import Image, ImageFilter

S = 1024


def hash2(ix, iy, seed=0):
    h = (ix * 374761393 + iy * 668265263 + seed * 2246822519) & 0xFFFFFFFF
    h = ((h ^ (h >> 13)) * 1274126177) & 0xFFFFFFFF
    return ((h ^ (h >> 16)) & 0xFFFF) / 65535.0


def vnoise(x, y, seed=0):
    ix, iy = np.floor(x).astype(np.int64), np.floor(y).astype(np.int64)
    fx, fy = x - ix, y - iy
    ux, uy = fx * fx * (3 - 2 * fx), fy * fy * (3 - 2 * fy)
    a, b = hash2(ix, iy, seed), hash2(ix + 1, iy, seed)
    c, d = hash2(ix, iy + 1, seed), hash2(ix + 1, iy + 1, seed)
    return (a + (b - a) * ux) * (1 - uy) + (c + (d - c) * ux) * uy


def fbm(x, y, octaves=5, seed=0):
    v, amp = 0.0, 0.5
    for o in range(octaves):
        v = v + amp * vnoise(x, y, seed + o)
        x, y, amp = x * 2.03, y * 2.03, amp * 0.5
    return v


def squircle_mask(size, margin=100, n=5.0):
    # Big Sur style continuous-corner rounded square (superellipse)
    yy, xx = np.mgrid[0:size, 0:size].astype(np.float64) + 0.5
    half = (size - 2 * margin) / 2
    cx = cy = size / 2
    nx, ny = np.abs(xx - cx) / half, np.abs(yy - cy) / half
    r = (nx ** n + ny ** n) ** (1 / n)
    aa = 1.5 / half
    return np.clip((1 - r) / aa + 0.5, 0, 1), r


def ramp(t, stops):
    t = np.clip(t, 0, 1)
    out = np.zeros(t.shape + (3,))
    for (t0, c0), (t1, c1) in zip(stops, stops[1:]):
        m = (t >= t0) & (t <= t1)
        k = ((t - t0) / (t1 - t0))[m][:, None]
        out[m] = np.array(c0) * (1 - k) + np.array(c1) * k
    return out


def render():
    mask, r = squircle_mask(S)
    yy, xx = np.mgrid[0:S, 0:S].astype(np.float64)
    u = (xx - S / 2) / (S / 2)          # -1..1, left→right
    v = (S - yy) / S                     # 0 bottom .. 1 top

    # --- background: deep black with a faint warm glow from below
    bg = np.zeros((S, S, 3))
    glow = np.exp(-((u / 0.75) ** 2 + ((v - 0.18) / 0.45) ** 2))
    bg += glow[..., None] * np.array([0.22, 0.05, 0.0])
    bg += (1 - v)[..., None] * np.array([0.03, 0.02, 0.02])

    # --- flame: several layered teardrop tongues distorted by noise
    def tongue(cx, bottom, height, half_w, seed, lean=0.0):
        t = (v - bottom) / height * 2 - 1                 # -1 bottom .. 1 tip
        n_a = fbm(u * 3.0 + seed, v * 2.6 - seed * 0.3, 5, seed=seed)
        n_b = fbm(u * 8.0 - seed, v * 7.0, 4, seed=seed + 50)
        hh = np.clip((t + 1) / 2, 0, 1)
        sway = cx + lean * hh ** 2 + (n_a - 0.5) * 0.28 * hh ** 1.2
        tt = np.clip(t + (n_b - 0.5) * 0.25 * hh, -1, 1)
        w = half_w * np.sqrt(np.clip(1 - tt ** 2, 0, 1)) * ((1 - tt) / 2) ** 0.75 * 1.9
        d = np.abs(u - sway) / np.maximum(w, 1e-4)
        inside = 1 - d
        inside = np.where((t < -1) | (t > 1), -1, inside)
        return np.clip(inside * 1.5 + (n_b - 0.5) * 0.35, 0, 1), hh

    f_main, hh = tongue(0.0, 0.18, 0.68, 0.38, seed=3, lean=0.06)
    f_left, _ = tongue(-0.22, 0.18, 0.40, 0.23, seed=21, lean=-0.10)
    f_right, _ = tongue(0.24, 0.18, 0.46, 0.23, seed=37, lean=0.12)
    flame = np.maximum(f_main, np.maximum(f_left * 0.85, f_right * 0.85))

    core, _ = tongue(0.0, 0.20, 0.38, 0.19, seed=5, lean=0.02)
    heat = np.clip(flame * 0.80 + core * 0.30, 0, 1.0)
    fire = ramp(heat, [
        (0.00, (0.0, 0.0, 0.0)),
        (0.15, (0.30, 0.02, 0.0)),
        (0.40, (0.82, 0.10, 0.02)),
        (0.62, (1.00, 0.36, 0.03)),
        (0.82, (1.00, 0.66, 0.16)),
        (1.00, (1.00, 0.92, 0.62)),
    ])
    alpha = np.clip(heat * 3.0, 0, 1)[..., None]
    img = bg * (1 - alpha) + fire * alpha

    # embers / sparks
    rng = np.random.default_rng(7)
    for _ in range(26):
        ex, ey = rng.normal(0, 0.30), rng.uniform(0.62, 0.90)
        rad = rng.uniform(0.006, 0.014)
        g = np.exp(-(((u - ex) ** 2 + (v - ey) ** 2) / rad ** 2))
        img += g[..., None] * np.array([1.0, 0.55, 0.12]) * rng.uniform(0.5, 1.0)

    # bloom
    pil = Image.fromarray((np.clip(img, 0, 1) * 255).astype(np.uint8))
    blur = np.asarray(pil.filter(ImageFilter.GaussianBlur(28))).astype(np.float64) / 255
    img = np.clip(img + blur * 0.35, 0, 1)

    # subtle top sheen + rim
    sheen = np.clip(1 - v, 0, 1) * 0 + np.exp(-((v - 0.95) / 0.12) ** 2) * 0.05
    img += sheen[..., None]
    rim = np.exp(-((r - 0.99) / 0.008) ** 2) * 0.10
    img += rim[..., None] * np.array([0.9, 0.7, 0.6])

    rgba = np.dstack([np.clip(img, 0, 1), mask])
    icon = Image.fromarray((rgba * 255).astype(np.uint8), "RGBA")

    # drop shadow, as macOS icons have
    shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    sh_alpha = Image.fromarray((mask * 120).astype(np.uint8)).filter(ImageFilter.GaussianBlur(14))
    shadow.putalpha(sh_alpha)
    canvas = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    canvas.alpha_composite(shadow, (0, 10))
    canvas.alpha_composite(icon)
    return canvas


def write_icns(images, path):
    # images: dict size->PIL image
    entries = [("icp4", 16), ("icp5", 32), ("ic07", 128), ("ic08", 256), ("ic09", 512),
               ("ic10", 1024), ("ic11", 32), ("ic12", 64), ("ic13", 256), ("ic14", 512)]
    chunks = b""
    for code, size in entries:
        buf = io.BytesIO()
        images[size].save(buf, "PNG")
        data = buf.getvalue()
        chunks += code.encode() + struct.pack(">I", len(data) + 8) + data
    with open(path, "wb") as f:
        f.write(b"icns" + struct.pack(">I", len(chunks) + 8) + chunks)


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "."
    os.makedirs(out, exist_ok=True)
    master = render()
    master.save(os.path.join(out, "AppIcon-1024.png"))
    sizes = {s: master.resize((s, s), Image.LANCZOS) for s in (16, 32, 64, 128, 256, 512, 1024)}
    iconset = os.path.join(out, "AppIcon.iconset")
    os.makedirs(iconset, exist_ok=True)
    for base in (16, 32, 128, 256, 512):
        sizes[base].save(os.path.join(iconset, f"icon_{base}x{base}.png"))
        sizes[base * 2].save(os.path.join(iconset, f"icon_{base}x{base}@2x.png"))
    write_icns(sizes, os.path.join(out, "AppIcon.icns"))
    print("icon written to", out)


if __name__ == "__main__":
    main()
