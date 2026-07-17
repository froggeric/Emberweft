#!/usr/bin/env bash
# Tools/fetch-sheep-genomes.sh — fetch public Electric Sheep .flam3 genomes.
#
# DATA-PRESERVATION tool. Each fetched ID is EITHER a sheep (1 flame) OR an edge
# (2 flames, a stored A->B transition). We download to a staging file, count
# flames, and file it under sheep/gen-NNN/ or edges/gen-NNN/. The edges.sqlite
# pair DB is rebuilt at the end (Tools/rebuild_edges_db.py).
#
# Three eras / URL patterns (sheep IDs are sparse; 404 = never existed):
#   historic (165, 169): genome at <id>/spex; IDs scraped from best/page/<N>.html
#   modern-A (242-245):  electricsheep.com/archives/generation-NNN/<id>/...flam3
#   modern-B (247, 248): v3d0.sheepserver.net/gen/NNN/<id>/...flam3  (HTTP only)
#
# IDEMPOTENT: skips any ID already present in sheep/ OR edges/. Safe to re-run.
# For the live flock (248) use the faster Tools/sync-live-flock.sh between full runs.
#
# Usage:
#   make fetch-sheep                 # all generations
#   GENS="248 165" make fetch-sheep  # specific generations
#   PARALLEL=16 make fetch-sheep
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$REPO_ROOT/genomes/electric-sheep"
PARALLEL="${PARALLEL:-8}"
GENS="${GENS:-165 169 191 198 242 243 244 245 247 248}"
STAGE="$(mktemp -d)"; trap 'rm -rf "$STAGE"' EXIT

cfg_for() {
  case "$1" in
    165|169|191|198) echo "0:spex";;
    242) echo "4000:es";;
    243) echo "18000:es";;
    244) echo "82000:es";;
    245) echo "5000:es";;
    247) echo "45000:v3d0";;
    248) echo "60000:v3d0";;   # live flock — generous ceiling; sync-live-flock keeps it current
    *) echo "0:unknown";;
  esac
}

mkdir -p "$DEST/sheep" "$DEST/edges"

# Place a downloaded genome by flame count: 1->sheep, 2->edge, else discard.
file_by_flames() {
  local gen=$1 tmp=$2 padded=$3
  local sheep="$DEST/sheep/gen-$gen/electricsheep.$gen.$padded.flam3"
  local edge="$DEST/edges/gen-$gen/electricsheep.$gen.$padded.flam3"
  local nf; nf=$(grep -c '<flame' "$tmp")
  case "$nf" in
    1) mkdir -p "$(dirname "$sheep")"; mv "$tmp" "$sheep";;
    2) mkdir -p "$(dirname "$edge")"; mv "$tmp" "$edge";;
    *) rm -f "$tmp";;
  esac
}
export -f file_by_flames; export DEST STAGE

enumerate_gen() {  # es / v3d0
  local gen=$1 kind=$2 maxid=$3
  echo "== gen $gen: enumerating 0..$maxid via $kind (parallel=$PARALLEL) =="
  seq 0 "$maxid" \
    | xargs -L1 -P "$PARALLEL" bash -c '
        gen="$1"; kind="$2"; id="$3"
        padded="$(printf "%05d" "$id")"
        sheep="'"$DEST"'/sheep/gen-$gen/electricsheep.$gen.$padded.flam3"
        edge="'"$DEST"'/edges/gen-$gen/electricsheep.$gen.$padded.flam3"
        [ -s "$sheep" ] || [ -s "$edge" ] && exit 0       # idempotent skip
        case "$kind" in
          es)   url="https://electricsheep.com/archives/generation-$gen/$id/electricsheep.$gen.$padded.flam3";;
          v3d0) url="http://v3d0.sheepserver.net/gen/$gen/$id/electricsheep.$gen.$padded.flam3";;
          *)    exit 0;;
        esac
        tmp="'"$STAGE"'/$gen.$padded.part"
        if curl -fsS -m 30 --retry 2 --retry-delay 1 -o "$tmp" "$url" 2>/dev/null && [ -s "$tmp" ]; then
          file_by_flames "$gen" "$tmp" "$padded"
        else
          rm -f "$tmp"
        fi
      ' _ "$gen" "$kind"
}

scrape_gen() {  # historic spex
  local gen=$1 base="https://electricsheep.com/archives/generation-$gen/best/page"
  local hi=1
  while [ "$(curl -s -m 15 -o /dev/null -w "%{http_code}" "$base/$hi.html")" = "200" ]; do hi=$((hi*2)); [ "$hi" -gt 4096 ] && break; done
  local lo=$((hi/2)) last=$lo
  while [ "$lo" -lt "$hi" ]; do mid=$(((lo+hi+1)/2)); if [ "$(curl -s -m 15 -o /dev/null -w "%{http_code}" "$base/$mid.html")" = "200" ]; then last=$mid; lo=$mid; else hi=$((mid-1)); fi; done
  local ids; ids="$(mktemp)"
  { curl -fsS -m 20 "$base/index.html" 2>/dev/null || true; for p in $(seq 1 "$last"); do curl -fsS -m 20 "$base/$p.html" 2>/dev/null || true; done; } \
    | grep -oE 'sheep/[0-9]+' | grep -oE '[0-9]+' | sort -un > "$ids"
  echo "== gen $gen (historic): $(wc -l <"$ids" | tr -d ' ') ids across $((last+1)) pages =="
  xargs -L1 -P "$PARALLEL" -I{} bash -c '
      gen="'"$gen"'"; id="$1"; padded="$(printf "%05d" "$id")"
      sheep="'"$DEST"'/sheep/gen-$gen/electricsheep.$gen.$padded.flam3"
      edge="'"$DEST"'/edges/gen-$gen/electricsheep.$gen.$padded.flam3"
      [ -s "$sheep" ] || [ -s "$edge" ] && exit 0
      url="https://electricsheep.com/archives/generation-$gen/$id/spex"
      tmp="'"$STAGE"'/$gen.$padded.part"
      if curl -fsS -m 30 --retry 2 --retry-delay 1 -o "$tmp" "$url" 2>/dev/null && [ -s "$tmp" ]; then
        file_by_flames "$gen" "$tmp" "$padded"
      else rm -f "$tmp"; fi
    ' _ {} < "$ids"
  rm -f "$ids"
}

for gen in $GENS; do
  cfg="$(cfg_for "$gen")"; maxid="${cfg%%:*}"; kind="${cfg##*:}"
  [ "$kind" = unknown ] && { echo "unknown generation $gen"; continue; }
  case "$kind" in es|v3d0) enumerate_gen "$gen" "$kind" "$maxid";; spex) scrape_gen "$gen";; esac
  echo "  gen $gen: $(find "$DEST/sheep/gen-$gen" "$DEST/edges/gen-$gen" -name '*.flam3' 2>/dev/null | wc -l | tr -d ' ') files"
done

echo "== rebuilding edges.sqlite =="
python3 "$REPO_ROOT/Tools/rebuild_edges_db.py"
echo "done -> $DEST"
