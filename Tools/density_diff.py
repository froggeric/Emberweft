#!/usr/bin/env python3
"""Tools/density_diff.py — localise the real-genome density-parity gap.

Renders genome `00256` with MATCHED no-blur params in BOTH Emberweft (CPU) and
flam3, then prints side-by-side density diagnostics:
  (a) pixel-brightness histogram (>=8 buckets) of each
  (b) % of pixels above thresholds {4, 32, 128}
  (c) centroid + active bbox of each

The goal is to localise the ~20 dB PSNR gap (Emberweft is "peakier": 78.5% vs
93.5% pixels above threshold at the same total light) to a specific image region
and rank the candidate causes for Task 6 to fix.

Sanitization (matches the Task 5 spec): override `passes=1 temporal_samples=1
supersample=1 estimator_radius=0 estimator_minimum=0 quality=1000` on the
input genome and feed the SAME sanitized file to BOTH renderers. This isolates
the chaos density + display pipeline (no motion blur, no DE, no supersampling).
`filter` (spatial filter radius) is left at the genome's native value so the
display pipeline runs through its real config — it is a ranked suspect (see
density_diff.md).

Matched parameters both sides:
  - size      = 800x592   (genome's native `size`)
  - oversample= 1         (sanitized)
  - quality   = 1000      (sanitized; Emberweft `--quality 1000`, flam3 via genome)
  - DE        = off       (sanitized; estimator_radius=0)
  - motion    = off       (sanitized; passes=1 temporal_samples=1)
  - ISAAC     = "emberweftgoldens" both sides (Emberweft default, flam3 `isaac_seed=`)
  - seed      = 42        (libc srandom; affects only flam3 aux RNG, not ISAAC)

Usage:
    python3 Tools/density_diff.py [--genome PATH] [--out DIR] [--keep-pngs]
Defaults: genome = Tests/Goldens/genomes_real/electricsheep.248.00256.flam3,
          out = /tmp/density_diff.

Prerequisites: `swift build` (Emberweft CLI on $PATH at .build/debug/emberweft);
flam3-render on $PATH (~/.local/bin/flam3-render); PIL + numpy (for image load).
"""
from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

try:
    import numpy as np
    from PIL import Image
except ImportError as e:
    sys.stderr.write(
        "ERROR: this tool needs PIL and numpy (`pip install pillow numpy`): "
        f"{e}\n")
    sys.exit(2)


REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_GENOME = REPO_ROOT / "Tests/Goldens/genomes_real/electricsheep.248.00256.flam3"
# Release build — the CPU reference processes ~width*height*quality samples
# (~473M for 800x592x1000). Debug-mode runtime is ~6+ min; release is ~25 s.
EMBERWEFT_BIN = REPO_ROOT / ".build/release/emberweft"
FLAM3_RENDER = shutil.which("flam3-render") or os.path.expanduser("~/.local/bin/flam3-render")
ISAAC_SEED = "emberweftgoldens"   # matches ChaosGame.goldenIsaacSeed
LIBC_SEED = "42"                  # matches Tools/regen_goldens.sh default

# Matched render parameters (both sides).
RENDER_WIDTH, RENDER_HEIGHT = 800, 592
RENDER_QUALITY = 1000


def sanitize_genome(src: Path, dst: Path, *, quality: int = RENDER_QUALITY) -> None:
    """Rewrite the genome with no-blur / no-DE / no-supersample / matched quality.

    Overwrites: passes, temporal_samples, supersample, estimator_radius,
                estimator_minimum, quality.
    Preserves:  size, center, scale, rotate, brightness, gamma, vibrancy,
                palette, xforms, and crucially `filter` (the spatial-filter
                radius — the display pipeline we are stress-testing).
    Idempotent: every attr is replaced via regex substitution.
    """
    text = src.read_text()
    repl = {
        r'passes="[^"]*"':            'passes="1"',
        r'temporal_samples="[^"]*"':  'temporal_samples="1"',
        r'supersample="[^"]*"':       'supersample="1"',
        r'estimator_radius="[^"]*"':  'estimator_radius="0"',
        r'estimator_minimum="[^"]*"': 'estimator_minimum="0"',
        r'quality="[^"]*"':           f'quality="{quality}"',
    }
    out = text
    for pat, repl_val in repl.items():
        out = re.sub(pat, repl_val, out)
    dst.write_text(out)


def run(cmd: list[str], *, env: dict | None = None, stdin: str | None = None,
        label: str) -> None:
    """Run a subprocess, streaming stderr to the console under a label."""
    sys.stderr.write(f"[{label}] $ {' '.join(cmd)}\n")
    if env:
        # Pretty-print env additions only (not the whole inherited env).
        additions = {k: v for k, v in env.items() if k not in os.environ or os.environ[k] != v}
        if additions:
            sys.stderr.write(f"[{label}] env: {additions}\n")
    res = subprocess.run(
        cmd, env={**os.environ, **(env or {})}, input=stdin,
        text=True, capture_output=True)
    if res.returncode != 0:
        sys.stderr.write(res.stderr)
        raise RuntimeError(f"{label} exited {res.returncode}")
    # flam3 emits progress on stderr; surface the tail so the user sees it ran.
    if res.stderr:
        tail = res.stderr.strip().splitlines()[-1] if res.stderr.strip() else ""
        if tail:
            sys.stderr.write(f"[{label}] {tail}\n")


def render_flam3(sanitized: Path, out_png: Path) -> None:
    """Render via flam3-render (env-var driven, no flags)."""
    if not FLAM3_RENDER or not Path(FLAM3_RENDER).exists():
        raise RuntimeError(
            f"flam3-render not found on $PATH or at {FLAM3_RENDER}; "
            "see Tools/flam3_oracle.sh")
    env = {
        "format": "png",
        "transparency": "0",
        "seed": LIBC_SEED,
        "isaac_seed": ISAAC_SEED,
        "nthreads": "1",   # single-threaded; matches Emberweft CPU's one ISAAC stream
        "in": str(sanitized),
        "out": str(out_png),
        "earlyclip": "0",  # default; Emberweft assumes the !earlyclip tone-map path
    }
    run([FLAM3_RENDER], env=env, label="flam3-render")


def render_emberweft(sanitized: Path, out_png: Path) -> None:
    """Render via the Emberweft CPU reference (`ReferenceRenderer.render`).

    The CPU path is the deterministic oracle-quality backend; `--backend cpu`
    is correct. `--seed` is accepted but only affects the Metal backend's
    thread seeds — the CPU chaos game is seeded purely from
    `ChaosGame.goldenIsaacSeed` ("emberweftgoldens"), matching flam3's
    `isaac_seed`. There is no `--isaac-seed` flag (the CPU path doesn't need
    one), so we don't fall back to a Swift snippet.
    """
    if not EMBERWEFT_BIN.exists():
        raise RuntimeError(
            f"emberweft CLI not built at {EMBERWEFT_BIN}; run `swift build`.")
    cmd = [
        str(EMBERWEFT_BIN), "render", str(sanitized),
        "--backend", "cpu",
        "--size", f"{RENDER_WIDTH}x{RENDER_HEIGHT}",
        "--quality", str(RENDER_QUALITY),
        "--seed", LIBC_SEED,
        "-o", str(out_png),
    ]
    run(cmd, label="emberweft render")


# ---------------------------------------------------------------------------
# Image analysis
# ---------------------------------------------------------------------------

# 8 brightness buckets covering the full 0..255 luminance range. The 32/128
# boundaries align with the {4,32,128} thresholds so the histogram and the
# threshold numbers cross-reference each other directly.
BUCKET_EDGES = [0, 4, 8, 16, 32, 64, 128, 192, 256]   # 8 buckets
THRESHOLDS = [4, 32, 128]


def luminance(rgb: np.ndarray) -> np.ndarray:
    """Per-pixel luminance in [0,255]. flam3/Rec.601 luma weights."""
    r, g, b = rgb[..., 0], rgb[..., 1], rgb[..., 2]
    return 0.299 * r + 0.587 * g + 0.114 * b


def stats(png: Path) -> dict:
    """Compute density diagnostics for one rendered PNG."""
    img = np.asarray(Image.open(png).convert("RGB"), dtype=np.float64)
    H, W = img.shape[:2]
    lum = luminance(img)
    flat = lum.reshape(-1)

    # (a) Histogram, >=8 buckets.
    counts, _ = np.histogram(flat, bins=BUCKET_EDGES)
    total_px = flat.size
    hist_pct = counts / total_px * 100.0

    # (b) % of pixels above thresholds.
    above = {t: float((flat > t).sum()) / total_px * 100.0 for t in THRESHOLDS}

    # (c) Centroid + active bbox (active = lum > 4, the lowest threshold).
    active = flat > THRESHOLDS[0]
    if active.any():
        ys, xs = np.nonzero(active.reshape(H, W))
        cx, cy = float(xs.mean()), float(ys.mean())
        bbox = (int(xs.min()), int(ys.min()), int(xs.max()), int(ys.max()))
        active_frac = float(active.sum()) / total_px * 100.0
    else:
        cx = cy = float("nan")
        bbox = (0, 0, 0, 0)
        active_frac = 0.0

    # Total light (sum of luminance) — proves whether the gap is redistribution
    # vs absolute brightness mismatch.
    total_light = float(flat.sum())
    mean = float(flat.mean())
    peak = float(flat.max())
    return {
        "size": (W, H),
        "hist_pct": hist_pct,
        "above": above,
        "centroid": (cx, cy),
        "bbox": bbox,
        "active_frac": active_frac,
        "total_light": total_light,
        "mean": mean,
        "peak": peak,
        "active_mean_lum": float(flat[active].mean()) if active.any() else 0.0,
    }


def fmt_hist(hist_pct: np.ndarray) -> str:
    """Format the 8-bucket histogram as a side-by-side string."""
    rows = []
    for i, lo in enumerate(BUCKET_EDGES[:-1]):
        hi = BUCKET_EDGES[i + 1]
        # Bar (each '#' ~= 0.5%).
        pct = hist_pct[i]
        bar = "#" * int(pct * 2)
        rows.append(f"  [{lo:>3},{hi:>3})  {pct:6.2f}%  {bar}")
    return "\n".join(rows)


def fmt_pct(v: float) -> str:
    return f"{v:6.2f}%"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--genome", type=Path, default=DEFAULT_GENOME,
                    help=f"input .flam3 genome (default: {DEFAULT_GENOME.name})")
    ap.add_argument("--out", type=Path, default=Path("/tmp/density_diff"),
                    help="working dir for sanitized genome + PNGs (default: /tmp/density_diff)")
    ap.add_argument("--keep-pngs", action="store_true", default=True,
                    help="keep the rendered PNGs in --out (default; for visual diff)")
    ap.add_argument("--quality", type=int, default=RENDER_QUALITY,
                    help=f"matched samples-per-pixel both sides (default: {RENDER_QUALITY})")
    args = ap.parse_args()

    if not args.genome.exists():
        sys.stderr.write(f"ERROR: genome not found: {args.genome}\n")
        return 2
    args.out.mkdir(parents=True, exist_ok=True)

    sanitized = args.out / f"{args.genome.stem}.sanitized.flam3"
    sanitize_genome(args.genome, sanitized, quality=args.quality)
    sys.stderr.write(f"[sanitize] wrote {sanitized}\n")

    flam3_png = args.out / f"{args.genome.stem}.flam3.png"
    emberweft_png = args.out / f"{args.genome.stem}.emberweft.png"

    # Render both sides. flam3 is ~2x faster than Emberweft CPU; run sequentially
    # so a single failure is easier to localise and stderr interleaves cleanly.
    if flam3_png.exists():
        sys.stderr.write(f"[flam3-render] reusing existing {flam3_png}\n")
    else:
        render_flam3(sanitized, flam3_png)
    if emberweft_png.exists():
        sys.stderr.write(f"[emberweft] reusing existing {emberweft_png}\n")
    else:
        render_emberweft(sanitized, emberweft_png)

    s_flam3 = stats(flam3_png)
    s_ember = stats(emberweft_png)

    # PSNR sanity-check so the report ties back to the headline gap.
    psnr = compute_psnr(flam3_png, emberweft_png)

    print_report(args.genome.name, s_flam3, s_ember, psnr,
                 sanitized, flam3_png, emberweft_png)
    return 0


def compute_psnr(a_png: Path, b_png: Path) -> float:
    """PSNR between two RGB PNGs (matches Emberweft's `ImageComparison`)."""
    a = np.asarray(Image.open(a_png).convert("RGB"), dtype=np.float64)
    b = np.asarray(Image.open(b_png).convert("RGB"), dtype=np.float64)
    if a.shape != b.shape:
        return float("nan")
    mse = float(((a - b) ** 2).mean())
    if mse == 0:
        return float("inf")
    return 10.0 * np.log10(255.0 ** 2 / mse)


def print_report(name: str, flam3: dict, ember: dict, psnr: float,
                 sanitized: Path, flam3_png: Path, emberweft_png: Path) -> None:
    bar = "=" * 78
    print(bar)
    print(f"  DENSITY-DIFF REPORT — {name}")
    print(f"  Sanitized:  {sanitized}")
    print(f"  flam3 PNG:  {flam3_png}")
    print(f"  Ember PNG:  {emberweft_png}")
    print(bar)
    print(f"  PSNR (flam3 vs Emberweft): {psnr:6.2f} dB   "
          f"(gate: 38 dB; known real-genome gap: ~20 dB)")
    print()
    print(f"  Image size:        flam3 = {flam3['size']}   "
          f"Emberweft = {ember['size']}")
    print(f"  Total light (Σ):   flam3 = {flam3['total_light']:14.0f}   "
          f"Emberweft = {ember['total_light']:14.0f}   "
          f"Δ = {(ember['total_light']-flam3['total_light'])/flam3['total_light']*100:+.1f}%")
    print(f"  Mean lum:          flam3 = {flam3['mean']:8.3f}   "
          f"Emberweft = {ember['mean']:8.3f}")
    print(f"  Peak lum:          flam3 = {flam3['peak']:8.1f}   "
          f"Emberweft = {ember['peak']:8.1f}")
    print(f"  Active pixel mean: flam3 = {flam3['active_mean_lum']:8.3f}   "
          f"Emberweft = {ember['active_mean_lum']:8.3f}   "
          f"(same total light, different distribution → peakier)")
    print()
    print("  " + "-" * 76)
    print(f"  HISTOGRAM (8 buckets, % of all {flam3['size'][0]*flam3['size'][1]} pixels)")
    print("  " + "-" * 76)
    print(f"  {'bucket':>14}      {'flam3':>10}   {'Emberweft':>10}   {'Δ pp':>8}")
    for i, lo in enumerate(BUCKET_EDGES[:-1]):
        hi = BUCKET_EDGES[i + 1]
        f, e = flam3["hist_pct"][i], ember["hist_pct"][i]
        d = e - f
        marker = "  <-- peakier tail" if d > 1.0 and lo >= 64 else ""
        print(f"  [{lo:>3},{hi:>3})        {f:>9.2f}%   {e:>9.2f}%   {d:>+7.2f}{marker}")
    print()
    print("  " + "-" * 76)
    print(f"  % PIXELS ABOVE THRESHOLD")
    print("  " + "-" * 76)
    print(f"  {'thr':>10}      {'flam3':>10}   {'Emberweft':>10}   {'Δ pp':>8}")
    for t in THRESHOLDS:
        f, e = flam3["above"][t], ember["above"][t]
        d = e - f
        print(f"  lum > {t:>3}      {f:>9.2f}%   {e:>9.2f}%   {d:>+7.2f}")
    print()
    print("  " + "-" * 76)
    print(f"  CENTROID + ACTIVE BBOX (active = lum > 4)")
    print("  " + "-" * 76)
    print(f"  Active fraction:   flam3 = {flam3['active_frac']:6.2f}%   "
          f"Emberweft = {ember['active_frac']:6.2f}%   "
          f"Δ = {ember['active_frac']-flam3['active_frac']:+.2f} pp")
    print(f"  Centroid (x, y):   flam3 = ({flam3['centroid'][0]:7.2f}, {flam3['centroid'][1]:7.2f})   "
          f"Emberweft = ({ember['centroid'][0]:7.2f}, {ember['centroid'][1]:7.2f})")
    print(f"  Active bbox:       flam3 = {flam3['bbox']}   "
          f"Emberweft = {ember['bbox']}")
    print()
    print(bar)


if __name__ == "__main__":
    raise SystemExit(main())
