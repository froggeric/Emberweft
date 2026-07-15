#!/usr/bin/env bash
# Tools/regen_goldens.sh — DEV-ONLY golden regeneration harness.
#
# Invokes the GPL flam3 oracle (built from source, OUTSIDE this repo) against
# the frozen `.flam3` genomes and writes one reference PNG per genome into
# Tests/Goldens/reference/. The committed PNGs let CI assert parity without
# ever needing flam3 installed.
#
# flam3 is GPL and is NEVER linked, bundled, copied, or distributed with
# Emberweft (PolyForm Noncommercial). It appears here only as a dev-only
# invocation. See Tests/Goldens/README.md and docs/license-and-attribution.md.
#
# Usage:
#   PATH="$HOME/flam3-oracle/bin:$PATH" make regen-goldens
set -euo pipefail

# Resolve repo root from script location so the target is cwd-independent.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GENOMES_DIR="$REPO_ROOT/Tests/Goldens/genomes"
OUT_DIR="$REPO_ROOT/Tests/Goldens/reference"
mkdir -p "$OUT_DIR"

# Locate the dev-only oracle: on PATH, else the standard from-source prefix.
ORACLE=""
if command -v flam3-render >/dev/null 2>&1; then
  ORACLE="flam3-render"
elif [ -x "$HOME/flam3-oracle/bin/flam3-render" ]; then
  ORACLE="$HOME/flam3-oracle/bin/flam3-render"
else
  echo "ERROR: flam3-render not found. Build the dev-only oracle; see Tests/Goldens/README.md (make bootstrap-oracle)." >&2
  exit 1
fi

# flam3 has TWO independent RNGs and both default to time-dependent values,
# making renders non-reproducible:
#   - libc (srandom): env `seed`,         default time(0)+getpid()
#   - ISAAC chaos-game: env `isaac_seed`, default time(0)   (string seed)
# Pin both so goldens are byte-stable across runs and machines. The defaults
# can be overridden from the environment to intentionally re-seed.
# Emberweft's own CPU render uses its own PCG32 seed; parity against these
# goldens is statistical (PSNR/SSIM, see Task 13) — the exact RNGs need not
# match, only be deterministic on each side.
export FLAM3_SEED="${FLAM3_SEED:-42}"
export FLAM3_ISAAC_SEED="${FLAM3_ISAAC_SEED:-emberweftgoldens}"

# Strip the volatile `flam3_time` tEXt chunk from a rendered PNG in place.
# Drops only that one metadata chunk; IDAT pixel data and all other chunks
# (genome, version, …) pass through byte-intact. Python stdlib only.
normalize_golden_png() {
  python3 - "$1" <<'PY'
import struct, sys
path = sys.argv[1]
data = open(path, 'rb').read()
assert data[:8] == b'\x89PNG\r\n\x1a\n', "not a PNG"
out = bytearray(data[:8])
i = 8
while i < len(data):
    ln = struct.unpack('>I', data[i:i+4])[0]
    typ = data[i+4:i+8]
    chunk = data[i:i+12+ln]
    i += 12 + ln
    if typ == b'tEXt':
        nul = chunk.index(b'\x00', 8)
        if chunk[8:nul] == b'flam3_time':
            continue   # drop volatile elapsed-seconds metadata
    out += chunk
    if typ == b'IEND':
        break
open(path, 'wb').write(out)
PY
}

count=0
for g in "$GENOMES_DIR"/*.flam3; do
  name=$(basename "$g" .flam3)
  echo "rendering golden: $name"
  # flam3-render takes ALL parameters as ENVIRONMENT VARIABLES (no -- flags).
  # size + quality are baked into each genome (no width/height/quality env var).
  env format=png transparency=0 \
      seed="$FLAM3_SEED" isaac_seed="$FLAM3_ISAAC_SEED" \
      in="$g" out="$OUT_DIR/$name.png" "$ORACLE" || {
    echo "ERROR: flam3-render rejected $g" >&2
    exit 1
  }
  # flam3 also embeds a `flam3_time` tEXt chunk recording the render's elapsed
  # seconds (e.g. "0" vs "1") — pixel-independent but it breaks byte-stable
  # `cmp` of the raw PNG under varying machine load. Strip just that one chunk
  # so committed goldens are byte-reproducible; IDAT (pixel) bytes are already
  # identical once the two seeds above are pinned. Uses only Python stdlib.
  normalize_golden_png "$OUT_DIR/$name.png"
  count=$((count + 1))
done

echo "rendered $count goldens -> $OUT_DIR"
ls -1 "$OUT_DIR"/*.png
