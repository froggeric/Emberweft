#!/usr/bin/env bash
# Tools/sync-live-flock.sh — efficiently back up NEW genomes from an in-progress
# (live) flock. Generation 248 is still actively growing: new sheep get higher
# IDs, so instead of re-enumerating the whole 0..N range every time, this script
# only probes the tail beyond what we already have.
#
# Algorithm:
#   1. local_max  = highest genome ID already present locally for the flock.
#   2. server_max = found by binary-searching the server from local_max upward.
#   3. fetch only (local_max, server_max], keeping the 200s (sparse IDs -> 404s
#      are expected and skipped).
#
# Idempotent and safe to run as often as you like (cron/launchd). Prints a one-
# line summary suitable for logs.
#
# Usage:
#   make sync-sheep                  # default: gen 248
#   GEN=248 PARALLEL=12 make sync-sheep
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$REPO_ROOT/genomes/electric-sheep"
GEN="${GEN:-248}"
PARALLEL="${PARALLEL:-8}"

# host kind per generation (mirror fetch-sheep-genomes.sh)
kind_for() { case "$1" in 247|248) echo v3d0;; *) echo es;; esac; }
url_for() {
  local gen=$1 id=$2 kind=$3 padded; padded=$(printf "%05d" "$id")
  case "$kind" in
    es)   echo "https://electricsheep.com/archives/generation-$gen/$id/electricsheep.$gen.$padded.flam3";;
    v3d0) echo "http://v3d0.sheepserver.net/gen/$gen/$id/electricsheep.$gen.$padded.flam3";;
  esac
}
exists_on_server() {  # gen id kind -> 0 if served (HTTP 200), 1 otherwise
  local url; url=$(url_for "$1" "$2" "$3")
  [ "$(curl -s -m 20 -o /dev/null -w "%{http_code}" "$url")" = "200" ]
}

dir="$DEST/gen-$GEN"
mkdir -p "$dir"
kind=$(kind_for "$GEN")

# 1. local max ID
local_max=$(find "$dir" -name "electricsheep.$GEN.*.flam3" 2>/dev/null \
  | grep -oE "\.$GEN\.[0-9]+\.flam3" | grep -oE "[0-9]+" | sort -n | tail -1)
local_max="${local_max:-0}"
local_count=$(find "$dir" -name '*.flam3' 2>/dev/null | wc -l | tr -d ' ')

# 2. binary-search server max starting just above local_max
probe=$((local_max + 1))
while exists_on_server "$GEN" "$probe" "$kind"; do probe=$((probe * 2 + 1)); done   # find a ceiling
lo=$local_max; hi=$probe
while [ "$((hi - lo))" -gt 1 ]; do
  mid=$(( (lo + hi) / 2 ))
  if exists_on_server "$GEN" "$mid" "$kind"; then lo=$mid; else hi=$mid; fi
done
server_max=$lo

if [ "$server_max" -le "$local_max" ]; then
  echo "gen $GEN: up to date (local_max=$local_max, $local_count genomes). No new sheep."
  exit 0
fi

# 3. fetch only the new tail (local_max, server_max]
echo "gen $GEN: local_max=$local_max -> server_max=$server_max; syncing new tail..."
seq $((local_max + 1)) "$server_max" \
  | xargs -L1 -P "$PARALLEL" bash -c '
      gen="$1"; kind="$2"; id="$3"
      padded="$(printf "%05d" "$id")"
      dir="'"$dir"'"; out="$dir/electricsheep.$gen.$padded.flam3"
      [ -s "$out" ] && exit 0
      case "$kind" in
        es)   url="https://electricsheep.com/archives/generation-$gen/$id/electricsheep.$gen.$padded.flam3";;
        v3d0) url="http://v3d0.sheepserver.net/gen/$gen/$id/electricsheep.$gen.$padded.flam3";;
      esac
      if curl -fsS -m 30 --retry 2 --retry-delay 1 -o "$out.part" "$url" 2>/dev/null \
         && [ -s "$out.part" ]; then mv "$out.part" "$out"; else rm -f "$out.part"; fi
    ' _ "$GEN" "$kind"

new_count=$(find "$dir" -name '*.flam3' 2>/dev/null | wc -l | tr -d ' ')
added=$((new_count - local_count))
echo "gen $GEN: +$added new genomes (now $new_count total, max id $server_max)."
