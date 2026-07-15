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

count=0
for g in "$GENOMES_DIR"/*.flam3; do
  name=$(basename "$g" .flam3)
  echo "rendering golden: $name"
  # flam3-render takes ALL parameters as ENVIRONMENT VARIABLES (no -- flags).
  # size + quality are baked into each genome (no width/height/quality env var).
  env format=png transparency=0 in="$g" out="$OUT_DIR/$name.png" "$ORACLE" || {
    echo "ERROR: flam3-render rejected $g" >&2
    exit 1
  }
  count=$((count + 1))
done

echo "rendered $count goldens -> $OUT_DIR"
ls -1 "$OUT_DIR"/*.png
