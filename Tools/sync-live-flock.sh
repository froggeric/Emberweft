#!/usr/bin/env bash
# Tools/sync-live-flock.sh — efficiently back up NEW genomes from an in-progress
# (live) flock. Generation 248 is still actively growing: new sheep/edges get
# higher IDs, so instead of re-enumerating 0..N every time, this only probes the
# tail beyond what we already have (counting BOTH sheep/ and edges/).
#
# Algorithm:
#   1. local_max  = highest ID present locally (in sheep/gen-N OR edges/gen-N).
#   2. server_max = binary-searched from local_max upward.
#   3. fetch (local_max, server_max], classifying each into sheep/ or edges/ by
#      flame count; then rebuild edges.sqlite.
#
# Idempotent; safe to run often (the launchd job runs this daily). One-line log.
#
# Usage:
#   make sync-sheep                  # default: gen 248
#   GEN=248 PARALLEL=12 make sync-sheep
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$REPO_ROOT/genomes/electric-sheep"
GEN="${GEN:-248}"
PARALLEL="${PARALLEL:-8}"
STAGE="$(mktemp -d)"; trap 'rm -rf "$STAGE"' EXIT

kind_for() { case "$1" in 247|248) echo v3d0;; *) echo es;; esac; }
url_for() {
  local gen=$1 id=$2 kind=$3 padded; padded=$(printf "%05d" "$id")
  case "$kind" in
    es)   echo "https://electricsheep.com/archives/generation-$gen/$id/electricsheep.$gen.$padded.flam3";;
    v3d0) echo "http://v3d0.sheepserver.net/gen/$gen/$id/electricsheep.$gen.$padded.flam3";;
  esac
}
exists_on_server() { [ "$(curl -s -m 20 -o /dev/null -w "%{http_code}" "$(url_for "$1" "$2" "$3")")" = "200" ]; }

mkdir -p "$DEST/sheep/gen-$GEN" "$DEST/edges/gen-$GEN"
kind=$(kind_for "$GEN")

# 1. local max ID across sheep/ AND edges/
local_max=$( { find "$DEST/sheep/gen-$GEN" "$DEST/edges/gen-$GEN" -name "electricsheep.$GEN.*.flam3" 2>/dev/null; } \
  | grep -oE "\.$GEN\.[0-9]+\.flam3" | grep -oE "[0-9]+" | sort -n | tail -1)
local_max="${local_max:-0}"
local_count=$(find "$DEST/sheep/gen-$GEN" "$DEST/edges/gen-$GEN" -name '*.flam3' 2>/dev/null | wc -l | tr -d ' ')

# 2. binary-search server max just above local_max
probe=$((local_max + 1))
while exists_on_server "$GEN" "$probe" "$kind"; do probe=$((probe * 2 + 1)); done
lo=$local_max; hi=$probe
while [ "$((hi - lo))" -gt 1 ]; do
  mid=$(( (lo + hi) / 2 ))
  if exists_on_server "$GEN" "$mid" "$kind"; then lo=$mid; else hi=$mid; fi
done
server_max=$lo

if [ "$server_max" -le "$local_max" ]; then
  echo "gen $GEN: up to date (local_max=$local_max, $local_count genomes). No new genomes."
  exit 0
fi

# 3. fetch the new tail, classify into sheep/ or edges/
echo "gen $GEN: local_max=$local_max -> server_max=$server_max; syncing new tail..."
file_by_flames() {
  local gen=$1 tmp=$2 padded=$3
  local sheep="$DEST/sheep/gen-$gen/electricsheep.$gen.$padded.flam3"
  local edge="$DEST/edges/gen-$gen/electricsheep.$gen.$padded.flam3"
  local nf; nf=$(grep -c '<flame' "$tmp")
  case "$nf" in 1) mkdir -p "$(dirname "$sheep")"; mv "$tmp" "$sheep";; 2) mkdir -p "$(dirname "$edge")"; mv "$tmp" "$edge";; *) rm -f "$tmp";; esac
}
export -f file_by_flames; export DEST STAGE

seq $((local_max + 1)) "$server_max" \
  | xargs -L1 -P "$PARALLEL" bash -c '
      gen="$1"; kind="$2"; id="$3"; padded="$(printf "%05d" "$id")"
      sheep="'"$DEST"'/sheep/gen-$gen/electricsheep.$gen.$padded.flam3"
      edge="'"$DEST"'/edges/gen-$gen/electricsheep.$gen.$padded.flam3"
      [ -s "$sheep" ] || [ -s "$edge" ] && exit 0
      case "$kind" in
        es)   url="https://electricsheep.com/archives/generation-$gen/$id/electricsheep.$gen.$padded.flam3";;
        v3d0) url="http://v3d0.sheepserver.net/gen/$gen/$id/electricsheep.$gen.$padded.flam3";;
      esac
      tmp="'"$STAGE"'/$gen.$padded.part"
      if curl -fsS -m 30 --retry 2 --retry-delay 1 -o "$tmp" "$url" 2>/dev/null && [ -s "$tmp" ]; then
        file_by_flames "$gen" "$tmp" "$padded"
      else rm -f "$tmp"; fi
    ' _ "$GEN" "$kind"

python3 "$REPO_ROOT/Tools/rebuild_edges_db.py"

new_count=$(find "$DEST/sheep/gen-$GEN" "$DEST/edges/gen-$GEN" -name '*.flam3' 2>/dev/null | wc -l | tr -d ' ')
echo "gen $GEN: +$((new_count - local_count)) new genomes (now $new_count total, max id $server_max)."
