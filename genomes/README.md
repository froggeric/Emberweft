# Electric Sheep genome library

A **data-preservation archive** of `.flam3` genomes from Scott Draves'
**Electric Sheep** — the community-evolved fractal-flame "sheep". These are the
*math* (the genome) behind each sheep, which Emberweft renders itself; they are
not rendered video.

## Why this exists

> The Electric Sheep archive is curated community-created art that is hard to
> obtain and could disappear at any time. This library preserves it: every
> available genome, committed to git so it survives independently of the original
> servers. This is as much a preservation project as a renderer resource.

The classic servers' listing pages are already partly broken (`best.cgi`/`dead.cgi`
serve source or time out), and the current `infinidream.ai` API exposes **only
rendered video (increasingly AI-generated) — no genomes**. The genomes live only
on the legacy flat-file hosts below, which motivates archiving them now.

## Structure

Genomes are split by kind, since the two render differently:

```
genomes/electric-sheep/
  sheep/gen-NNN/*.flam3   # 47,304 single-frame SHEEP (the renderable library; stills)
  edges/gen-NNN/*.flam3   # 75,743 two-frame EDGES (stored A->B transitions)
  edges.sqlite            # pair DB: every edge resolved to its two endpoint sheep
  _malformed/             # 10 empty/invalid files (quarantined)
  _provenance-earthbound19/
```

A **sheep** is a single `<flame>` (a still design — its motion is generated on
the fly by `sheep_loop`, see [transitions.md](../../docs/rendering/transitions.md)).
An **edge** is two `<flame>`s — a stored A→B transition. An edge is byte-identical
to its two endpoint sheep (modulo `time`/edits), so Emberweft generates transitions
**on the fly** and treats the edges only as a curation oracle.

## Inventory

| Generation | Era | Sheep | Edges | Source |
|------------|-----|------:|------:|--------|
| 165 | historic | 7,316 | 23,217 | scraped best-page |
| 169 | historic | 5,299 | 16,444 | scraped best-page |
| 191 | historic | 1,491 | 0 | scraped best-page |
| 198 | historic | 3,627 | 0 | scraped best-page |
| 242 | modern | 1,168 | 2,220 | earthbound19 backup (complete) |
| 243 | modern | 5,127 | 110 | backup + gap-filled |
| 244 | modern | 6,298 | 14,364 | backup + gap-filled |
| 245 | modern | 473 | 1,016 | direct from archive |
| 247 | modern | 7,042 | 8,604 | backup + gap-filled |
| 248 | **live** | 9,463 | 9,768 | direct from server (still growing) |
| **Total** | | **47,304** | **75,743** | **~1.6 GB** |

173 sheep existed only as edge endpoints and were extracted into `sheep/` so the
library is complete. Run `make fetch-sheep` to refresh (idempotent); `make
sync-sheep` for the live flock.

## Transition-pairs database (`edges.sqlite`)

`Tools/rebuild_edges_db.py` resolves every edge to its two endpoint sheep (by
content hash, falling back to name) and writes `edges.sqlite`:

| column | meaning |
|--------|---------|
| `edge_gen`, `edge_id` | the edge file's own generation + id |
| `a_gen`, `a_id`, `b_gen`, `b_id` | the two endpoint sheep |
| `frames` | frame extent (2nd `time` value) |
| `resolved` | 1 if both endpoints map to a standalone sheep |
| `sim_score`, `curated` | **reserved** for future similarity scoring / manual curation |

```sql
sqlite3 genomes/electric-sheep/edges.sqlite \
  "SELECT a_id,b_id FROM edge_pairs WHERE edge_gen='244' AND a_id='00980' LIMIT 5;"
```

All 75,743 edges resolve (0 unresolved). The DB is the efficient, enhanceable
source for the "good transition pairs" oracle.

### Pair selection (similarity, with exploration)

ES likely picked pairs near-randomly within flocks. Emberweft will pick **on the
fly by a similarity metric** for visually coherent morphs — but with a guard
against getting trapped in a small similar cluster: selection must allow
**exploration** (e.g. ε-greedy / temperature / occasional long-range jumps) so
playback traverses the full diversity of the library, not just a tight
neighborhood. The `sim_score`/`curated` columns are where that lands.

## Sources — three eras, three URL patterns

All public, no login. Sheep IDs are sparse within a generation — a 404 means that
sheep never existed.

```
# historic (165, 169, 191, 198): genome served as escaped XML at <id>/spex;
# IDs discovered by scraping best/page/<N>.html (256 sheep/page).
https://electricsheep.com/archives/generation-<gen>/<id>/spex

# modern-A (242, 243, 244, 245):
https://electricsheep.com/archives/generation-<gen>/<id>/electricsheep.<gen>.<id>.flam3

# modern-B (247, 248) — HTTP only:
http://v3d0.sheepserver.net/gen/<gen>/<id>/electricsheep.<gen>.<id>.flam3
```

`<id>` is zero-padded to 5 digits in the filename (historic `spex` URLs use the
raw id).

## Fetching & keeping current

```
make fetch-sheep                 # full archive of every generation (idempotent)
GENS="248 165" make fetch-sheep  # specific generations
PARALLEL=16 make fetch-sheep     # more concurrency
make sync-sheep                  # NEW genomes only, from the live flock (gen 248)
GEN=248 make sync-sheep
```

`fetch-sheep` (`Tools/fetch-sheep-genomes.sh`) is **idempotent** — it skips any
ID already present in `sheep/` or `edges/`, downloads new ones, **classifies by
flame count** (1→`sheep/`, 2→`edges/`), then rebuilds `edges.sqlite`. Add a
generation by extending `cfg_for`.

`sync-sheep` (`Tools/sync-live-flock.sh`) is the efficient path for the live
flock: it finds the highest local ID (across `sheep/`+`edges/`), binary-searches
the server's current max, fetches **only the new tail**, classifies it, and
rebuilds the DB. Cheap to run often.

### Recurring backup

Two ways to keep gen 248 archived as it grows:

**1. Standalone (runs without Claude) — recommended for unattended backup.**
A launchd job that runs `make sync-sheep` daily and commits any new genomes:

```bash
# install: cp to ~/Library/LaunchAgents/ and load (edit the repo path)
cat > ~/Library/LaunchAgents/com.emberweft.sheep-sync.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.emberweft.sheep-sync</string>
  <key>ProgramArguments</key><array>
    <string>/bin/sh</string><string>-c</string>
    <string>cd /Volumes/ssd/github/emberweft &amp;&amp; make sync-sheep &amp;&amp; git add genomes/ &amp;&amp; git commit -m 'chore(genomes): auto-sync gen-248' &amp;&amp; git push</string>
  </array>
  <key>StartCalendarInterval</key><dict><key>Hour</key><integer>8</integer><key>Minute</key><integer>17</integer></dict>
</dict></plist>
EOF
launchctl load ~/Library/LaunchAgents/com.emberweft.sheep-sync.plist
```

**2. In-session.** A Claude scheduled task (this repo) runs `make sync-sheep`
daily while Claude is active. It auto-expires after 7 days; re-create with
`make fetch-sheep`/`sync-sheep` context if needed.

## Provenance

- **Historic (165–198):** scraped directly from `electricsheep.com/archives`
  best-page listings.
- **Modern 242–247:** seeded from the
  [`earthbound19/electric_sheep_genomes`](https://github.com/earthbound19/electric_sheep_genomes)
  community backup, then gap-filled from the archive servers. (That backup's
  gen 247 stops at id 33486; the server serves sheep to ~44000 — the fetcher
  recovers the 3,769 missing ones. Its gen 244 stops at 72110; the server goes
  to ~78000.)
- **Modern 248:** fetched directly from the server; not in any known backup, and
  still growing.

earthbound19's upstream README and curated picks list are kept under
`electric-sheep/_provenance-earthbound19/`.

## License & attribution

- **Historic genomes (gens 165–198):** **CC-BY-SA 1.0** (per the archive pages).
- **Modern genomes:** **CC-BY** (human-designed) or **CC-BY-NC** (robot/"brood"-
  designed).

Both are compatible with Emberweft's source-available PolyForm Noncommercial
posture and the CC-BY-NC seed library. "Gold" sheep are the **same genome** as a
standard sheep, only historically rendered at higher resolution — no separate
license restriction on the genome itself.

The fractal flame algorithm was created by **Scott Draves** in 1992; "Electric
Sheep" and "Infinidream" are trademarks of Scott Draves / e-dream, inc. This is
an independent preservation archive of community-submitted `.flam3` files, not
affiliated with or endorsed by the Electric Sheep / Infinidream project.

## Relation to Emberweft

This library is the raw material for the M4 **seed library** (a curated,
hand/render-picked "best" set). The full archive lives here; a curated subset
will be promoted to `curated/` and surfaced in the app.
