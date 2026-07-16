#!/usr/bin/env bash
# Tools/fetch-sheep-genomes.sh — fetch public Electric Sheep .flam3 genomes.
#
# This is a DATA-PRESERVATION tool. The classic Electric Sheep archive is
# curated community-created art that is hard to obtain and could disappear; this
# script captures every available genome into genomes/electric-sheep/ for the
# Emberweft genome library. All sources are public (no login, no API).
#
# Three eras, three URL patterns (sheep IDs are sparse — a 404 means that sheep
# never existed):
#
#   historic (165, 169, 191, 198):
#     genome: https://electricsheep.com/archives/generation-NNN/<id>/spex
#     IDs discovered by scraping best/page/<N>.html (256 sheep/page).
#
#   modern-A (242, 243, 244, 245):
#     https://electricsheep.com/archives/generation-NNN/<id>/electricsheep.NNN.<id>.flam3
#
#   modern-B (247, 248 — HTTP only):
#     http://v3d0.sheepserver.net/gen/NNN/<id>/electricsheep.NNN.<id>.flam3
#
# IDEMPOTENT: existing genomes are skipped, so re-runs only fill gaps. Safe to
# interrupt and resume. For the live, in-progress flock (gen 248) use the faster
# Tools/sync-live-flock.sh between full runs.
#
# Usage:
#   make fetch-sheep                 # all generations (default parallelism)
#   GENS="248 165" make fetch-sheep  # specific generations
#   PARALLEL=16 make fetch-sheep     # more concurrency
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$REPO_ROOT/genomes/electric-sheep"
PARALLEL="${PARALLEL:-8}"
GENS="${GENS:-165 169 191 198 242 243 244 245 247 248}"

# Per-generation config: "<max_id>:<kind>".
#   kind = es   -> modern-A flat file on electricsheep.com (enumerate 0..max_id)
#   kind = v3d0 -> modern-B flat file on v3d0.sheepserver.net (enumerate 0..max_id)
#   kind = spex -> historic: scrape best/page listing, fetch <id>/spex (max_id ignored)
# max_id is an upper bound only; overestimating is harmless (extra 404s).
cfg_for() {
  case "$1" in
    165) echo "0:spex";;
    169) echo "0:spex";;
    191) echo "0:spex";;
    198) echo "0:spex";;
    242) echo "4000:es";;
    243) echo "18000:es";;
    244) echo "82000:es";;
    245) echo "5000:es";;
    247) echo "45000:v3d0";;
    248) echo "60000:v3d0";;   # live flock — generous ceiling; sync-live-flock.sh keeps it current
    *)   echo "0:unknown";;
  esac
}

mkdir -p "$DEST"

# --- modern enumeration worker (es / v3d0) -----------------------------------
# Args via xargs -L1: gen kind id
enumerate_gen() {
  local gen=$1 kind=$2 maxid=$3
  echo "== gen $gen: enumerating ids 0..$maxid via $kind (parallel=$PARALLEL) =="
  seq 0 "$maxid" \
    | xargs -L1 -P "$PARALLEL" bash -c '
        gen="$1"; kind="$2"; id="$3"
        padded="$(printf "%05d" "$id")"
        dir="'"$DEST"'/gen-$gen"
        out="$dir/electricsheep.$gen.$padded.flam3"
        [ -s "$out" ] && exit 0                      # idempotent skip
        case "$kind" in
          es)   url="https://electricsheep.com/archives/generation-$gen/$id/electricsheep.$gen.$padded.flam3";;
          v3d0) url="http://v3d0.sheepserver.net/gen/$gen/$id/electricsheep.$gen.$padded.flam3";;
          *)    exit 0;;
        esac
        if curl -fsS -m 30 --retry 2 --retry-delay 1 -o "$out.part" "$url" 2>/dev/null \
           && [ -s "$out.part" ]; then
          mv "$out.part" "$out"
        else
          rm -f "$out.part"
        fi
      ' _ "$gen" "$kind"
}

# --- historic spex scraper ----------------------------------------------------
# best/page is paginated (index.html = first, then 1.html, 2.html, …). Binary-
# search the last page, scrape every page for sheep IDs, fetch <id>/spex each.
scrape_gen() {
  local gen=$1
  local dir="$DEST/gen-$gen"
  mkdir -p "$dir"
  local base="https://electricsheep.com/archives/generation-$gen/best/page"

  # binary-search the last page (probe ascending ceilings, then narrow)
  local hi=1
  while [ "$(curl -s -m 15 -o /dev/null -w "%{http_code}" "$base/$hi.html")" = "200" ]; do
    hi=$((hi * 2))
    [ "$hi" -gt 4096 ] && break
  done
  local lo=$((hi / 2))
  local last=$lo
  while [ "$lo" -lt "$hi" ]; do
    mid=$(( (lo + hi + 1) / 2 ))
    if [ "$(curl -s -m 15 -o /dev/null -w "%{http_code}" "$base/$mid.html")" = "200" ]; then
      last=$mid; lo=$mid
    else
      hi=$((mid - 1))
    fi
  done

  # collect all sheep IDs across index.html + 1.html..last.html
  local ids_file; ids_file="$(mktemp)"
  { curl -fsS -m 20 "$base/index.html" 2>/dev/null || true; \
    for p in $(seq 1 "$last"); do curl -fsS -m 20 "$base/$p.html" 2>/dev/null || true; done; } \
    | grep -oE 'sheep/[0-9]+' | grep -oE '[0-9]+' | sort -un > "$ids_file"
  local total; total=$(wc -l < "$ids_file" | tr -d ' ')
  echo "== gen $gen (historic): $total unique sheep across $(($last + 1)) pages; fetching spex =="

  # fetch each genome's spex (idempotent). IDs are not zero-padded in the URL.
  xargs -L1 -P "$PARALLEL" -I{} bash -c '
      gen="'"$gen"'"; id="$1"; dir="'"$dir"'"
      out="$dir/electricsheep.$gen.$(printf "%05d" "$id").flam3"
      [ -s "$out" ] && exit 0
      url="https://electricsheep.com/archives/generation-$gen/$id/spex"
      if curl -fsS -m 30 --retry 2 --retry-delay 1 -o "$out.part" "$url" 2>/dev/null \
         && [ -s "$out.part" ]; then
        mv "$out.part" "$out"
      else
        rm -f "$out.part"
      fi
    ' _ {} < "$ids_file"
  rm -f "$ids_file"
}

for gen in $GENS; do
  cfg="$(cfg_for "$gen")"
  maxid="${cfg%%:*}"
  kind="${cfg##*:}"
  [ "$kind" = "unknown" ] && { echo "unknown generation $gen (add it to cfg_for)"; continue; }
  mkdir -p "$DEST/gen-$gen"
  case "$kind" in
    es|v3d0) enumerate_gen "$gen" "$kind" "$maxid" ;;
    spex)    scrape_gen "$gen" ;;
  esac
  cnt="$(find "$DEST/gen-$gen" -name '*.flam3' 2>/dev/null | wc -l | tr -d ' ')"
  echo "== gen $gen: $cnt genomes under $DEST/gen-$gen =="
done

echo
echo "summary:"
for gen in $GENS; do
  cnt="$(find "$DEST/gen-$gen" -name '*.flam3' 2>/dev/null | wc -l | tr -d ' ')"
  echo "  gen $gen: $cnt"
done
echo "done -> $DEST"
