#!/usr/bin/env bash
# Tools/fetch-sheep-genomes.sh — fetch public Electric Sheep .flam3 genomes.
#
# The classic Electric Sheep archive exposes every sheep's genome as a flat file
# on one of two hosts (no login, no API):
#   electricsheep.com/archives/generation-NNN/<id>/electricsheep.NNN.<id>.flam3   (gens 242-244)
#   v3d0.sheepserver.net/gen/NNN/<id>/electricsheep.NNN.<id>.flam3                (gens 247, 248)
# Sheep IDs are sparse within a generation: a 404 simply means that sheep never
# existed. We enumerate the ID range and keep the 200s.
#
# The script is IDEMPOTENT: it skips any genome already present, so it is safe to
# re-run to fill gaps — e.g. after seeding genomes/ from the earthbound19 backup,
# or to pick up a later generation. Partial/interrupted runs resume cleanly.
#
# NOTE on Infinidream: the current infinidream.ai REST API exposes only rendered
# video (increasingly AI-generated); it has NO genome field. Genomes for all
# generations remain on the classic archive hosts above. Do not try to fetch
# genomes from api-alpha.infinidream.ai.
#
# Usage:
#   make fetch-sheep                 # default generations, default parallelism
#   GENS="247 248" make fetch-sheep  # specific generations (e.g. gap-fill / newest)
#   PARALLEL=16 make fetch-sheep     # more concurrency (be polite to the server)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$REPO_ROOT/genomes/electric-sheep"
PARALLEL="${PARALLEL:-8}"
GENS="${GENS:-242 243 244 247 248}"

# Per-generation config: "<max_id>:<host>". max_id is an upper bound only; the
# real set is sparse so most probes 404 harmlessly. Raise a max_id to enumerate
# further into a generation.
cfg_for() {
  case "$1" in
    242) echo "4000:es";;
    243) echo "18000:es";;
    244) echo "72200:es";;
    247) echo "45000:v3d0";;
    248) echo "45000:v3d0";;
    *)   echo "0:unknown";;
  esac
}

mkdir -p "$DEST"

for gen in $GENS; do
  cfg="$(cfg_for "$gen")"
  maxid="${cfg%%:*}"
  kind="${cfg##*:}"
  [ "$kind" = "unknown" ] && { echo "unknown generation $gen (add it to cfg_for)"; continue; }
  mkdir -p "$DEST/gen-$gen"

  echo "== gen $gen: enumerating ids 0..$maxid via $kind (parallel=$PARALLEL) =="

  # Worker: fetch one genome idempotently. Args (via xargs -L1): gen kind id.
  # Inline (not an exported function) so it works under macOS bash 3.2 subshells.
  seq 0 "$maxid" \
    | xargs -L1 -P "$PARALLEL" bash -c '
        gen="$1"; kind="$2"; id="$3"
        padded="$(printf "%05d" "$id")"
        dir="'"$DEST"'/gen-$gen"
        out="$dir/electricsheep.$gen.$padded.flam3"
        # Idempotent: skip genomes already fetched.
        [ -s "$out" ] && exit 0
        case "$kind" in
          es)   url="https://electricsheep.com/archives/generation-$gen/$id/electricsheep.$gen.$padded.flam3";;
          v3d0) url="http://v3d0.sheepserver.net/gen/$gen/$id/electricsheep.$gen.$padded.flam3";;
          *)    exit 0;;
        esac
        if curl -fsS -m 30 --retry 2 --retry-delay 1 -o "$out.part" "$url" 2>/dev/null \
           && [ -s "$out.part" ]; then
          mv "$out.part" "$out"
        else
          rm -f "$out.part"   # 404 / transient — leaves no empty file
        fi
      ' _ "$gen" "$kind"

  cnt="$(find "$DEST/gen-$gen" -name '*.flam3' | wc -l | tr -d ' ')"
  echo "== gen $gen: $cnt genomes under $DEST/gen-$gen =="
done

echo
echo "summary:"
for gen in $GENS; do
  cnt="$(find "$DEST/gen-$gen" -name '*.flam3' 2>/dev/null | wc -l | tr -d ' ')"
  echo "  gen $gen: $cnt"
done
echo "done -> $DEST"
