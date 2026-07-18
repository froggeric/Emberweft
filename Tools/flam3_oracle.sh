#!/usr/bin/env bash
# Tools/flam3_oracle.sh
#
# Build instructions + the literal env-var invocations for the locally-built
# flam3 parity oracle (flam3-genome / flam3-animate). This is a DOCUMENTED
# helper — it is NOT run by CI and flam3 is NEVER linked into or distributed
# with Emberweft (see docs/license-and-attribution.md). The harness in
# Tests/FlameReferenceTests/Flam3Oracle.swift spawns these two binaries via
# Process; when they are absent from $PATH every vs-flam3 test auto-skips (F10).
#
# flam3 has NO Homebrew formula. It is built from source.
#
# ------------------------------------------------------------------------------
# 1. Build dependencies (one-time, dev machine)
# ------------------------------------------------------------------------------
#   brew install libpng libxml2 zlib automake autoconf libtool jpeg
#
# libxml2 and zlib are keg-only on Homebrew, so the configure step below points
# the compiler/linker at the opt prefixes explicitly.
#
# ------------------------------------------------------------------------------
# 2. Clone + build flam3 at the PINNED commit
# ------------------------------------------------------------------------------
# PINNED COMMIT:  f8b6c782012e4d922ef2cc2f0c2686b612c32504
#   (master as of 2024-12-31: "fix symmetry singularities by enforcing
#    maxforms from the beginning instead of the end". Bumps past the last
#    tag v3.1.1 (2015). Re-pin deliberately if you want to move forward.)
#
#   git clone https://github.com/scottdraves/flam3.git /tmp/flam3
#   cd /tmp/flam3
#   git checkout f8b6c782012e4d922ef2cc2f0c2686b612c32504
#
#   PKG_CONFIG_PATH="/opt/homebrew/opt/zlib/lib/pkgconfig:\
# /opt/homebrew/opt/libxml2/lib/pkgconfig:\
# /opt/homebrew/opt/libpng/lib/pkgconfig:\
# /opt/homebrew/opt/jpeg/lib/pkgconfig" \
#   LDFLAGS="-L/opt/homebrew/opt/zlib/lib -L/opt/homebrew/opt/libxml2/lib \
# -L/opt/homebrew/opt/libpng/lib -L/opt/homebrew/opt/jpeg/lib" \
#   CPPFLAGS="-I/opt/homebrew/opt/zlib/include -I/opt/homebrew/opt/libxml2/include \
# -I/opt/homebrew/opt/libpng/include -I/opt/homebrew/opt/jpeg/include" \
#   ./configure && make -j8
#
# ------------------------------------------------------------------------------
# 3. Put the two binaries on $PATH (e.g. symlink into ~/.local/bin)
# ------------------------------------------------------------------------------
#   ln -sf /tmp/flam3/flam3-genome  ~/.local/bin/flam3-genome
#   ln -sf /tmp/flam3/flam3-animate ~/.local/bin/flam3-animate
#
# OPTIONAL (silences the "could not open palette file" warning when rendering
# genomes WITHOUT an embedded <palette>; our oracle genomes always embed one, so
# this is cosmetic): copy the bundled palettes where the binary looks for them:
#   sudo mkdir -p /usr/local/share/flam3
#   sudo cp /tmp/flam3/flam3-palettes.xml /usr/local/share/flam3/
#
# Verify:
#   which flam3-genome flam3-animate    # both must resolve
#
# ------------------------------------------------------------------------------
# 4. The literal env-var invocations (NO CLI flags — everything is env vars)
# ------------------------------------------------------------------------------
# flam3-genome modes (flam3-genome.c:451-475):
#   sequence = whole loop+edge chain for N stills
#   rotate   = one loop
#   inter    = one edge (requires EXACTLY 2 control points)
#
# Generate a full loop+edge motion genome for a list of stills:
#   env sequence=stillA.flam3 nframes=160 flam3-genome > seq.flam3
#
# Generate one loop / one edge at a given frame:
#   env rotate=stillA.flam3 frame=80 nframes=160 flam3-genome > loop80.flam3
#   env inter=pair.flam3     frame=80 nframes=160 flam3-genome > edge80.flam3
#
# flam3-animate renders a motion genome to a PNG sequence. begin/end/prefix are
# env vars:
#   env begin=0 end=160 prefix=out. flam3-animate < seq.flam3
#
# ------------------------------------------------------------------------------
# 5. MOTION-BLUR-OFF for clean parity (F6) — genome ATTRIBUTES, not env vars
# ------------------------------------------------------------------------------
# flam3-animate's temporal oversampling (motion blur) is always on by default:
# passes (default 1) x temporal_samples (default 1000 => ~1000 sub-samples/frame
# across a +/-0.5-frame window — substantial blur). To disable it for clean
# vs-Emberweft parity, set  passes="1"  AND  temporal_samples="1"  on EVERY
# <flame> control point in the genome, e.g. with sed before piping to
# flam3-animate:
#   sed 's/<flame /<flame passes="1" temporal_samples="1" /g' seq.flam3 \
#     | env begin=0 end=160 prefix=out. flam3-animate
# The Swift harness (Flam3Oracle.renderFrames) injects these attributes the same
# way before spawning flam3-animate. Without this, the >=30 dB vs-flam3 gate
# would fail systematically on transition interiors (motion-blur signal, not a
# port bug). See docs/superpowers/specs/2026-07-17-m3-animation-design.md (F6).
# ------------------------------------------------------------------------------

set -euo pipefail

echo "This script is a documented reference; it does not auto-build flam3."
echo "Run the commands above manually (the brew/configure steps may be interactive)."
echo "See docs/engineering/testing.md for the oracle prerequisite and F10 auto-skip."

# Quick availability check used as a sanity probe:
if command -v flam3-genome >/dev/null 2>&1 && command -v flam3-animate >/dev/null 2>&1; then
    echo "OK: flam3-genome and flam3-animate resolve on PATH."
    command -v flam3-genome
    command -v flam3-animate
else
    echo "MISSING: flam3-genome / flam3-animate not on PATH."
    echo "         vs-flam3 tests will auto-skip (F10)."
fi
