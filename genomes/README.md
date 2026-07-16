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

## Inventory

Organized by generation under `electric-sheep/gen-NNN/`, canonical filenames
`electricsheep.<gen>.<id>.flam3` preserved.

| Generation | Era | Genomes | Source |
|------------|-----|---------|--------|
| 165 | historic | 30,499 | scraped best-page (electricsheep.com) |
| 169 | historic | 21,741 | scraped best-page |
| 191 | historic | 1,491 | scraped best-page |
| 198 | historic | 3,627 | scraped best-page |
| 242 | modern | 3,388 | earthbound19 backup (complete) |
| 243 | modern | 5,245 | backup (2,269) + 2,976 gap-filled |
| 244 | modern | 20,527 | backup (17,014) + 3,513 gap-filled |
| 245 | modern | 1,489 | direct from archive |
| 247 | modern | 15,646 | backup (11,877) + 3,769 gap-filled |
| 248 | **live** | 19,231 | direct from server (still growing) |
| **Total** | | **~122,884** | **~1.6 GB** |

Run `make fetch-sheep` to refresh these (idempotent); `make sync-sheep` for the
live flock.

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

`fetch-sheep` (`Tools/fetch-sheep-genomes.sh`) is **idempotent** — it skips
genomes already present, so re-runs only fill gaps and pick up new generations.
Add a generation by extending `cfg_for`.

`sync-sheep` (`Tools/sync-live-flock.sh`) is the efficient path for the live
flock: instead of re-enumerating 0..N every time, it finds the highest local ID,
binary-searches the server's current max, and fetches **only the new tail**. Cheap
to run often.

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
    <string>cd /Volumes/ssd/github/electricsheep &amp;&amp; make sync-sheep &amp;&amp; git add genomes/ &amp;&amp; git commit -m 'chore(genomes): auto-sync gen-248' &amp;&amp; git push</string>
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
