# Electric Sheep genome library

Curated `.flam3` genomes from Scott Draves' **Electric Sheep** — the
community-evolved fractal-flame "sheep". These are the *math* (the genome) behind
each sheep, which Emberweft renders itself; they are **not** rendered video.

Genomes are organized by generation under `electric-sheep/gen-NNN/`, preserving
the archive's canonical filename `electricsheep.<gen>.<id>.flam3`.

## Inventory

| Generation | Genomes | Source |
|------------|---------|--------|
| 242 | 3,388 | earthbound19 backup → classic archive |
| 243 | 2,269 | earthbound19 backup → classic archive |
| 244 | 17,014 | earthbound19 backup → classic archive |
| 247 | 15,646 | earthbound19 backup (11,877) + 3,769 gap-filled from server |
| 248 | 19,231 | direct server (newest flock, not in any backup) |
| **Total** | **57,548** | **~1.2 GB** |

Counts are filled in by `make fetch-sheep`; run it to refresh them.

## Sources & URL patterns

All genomes are **public, no login**. The classic archive serves each sheep's
genome as a flat file on one of two hosts (sheep IDs are sparse within a
generation — a 404 just means that sheep never existed):

```
# older generations (242-244)
https://electricsheep.com/archives/generation-<gen>/<id>/electricsheep.<gen>.<id>.flam3

# newer generations (247, 248) — HTTP only
http://v3d0.sheepserver.net/gen/<gen>/<id>/electricsheep.<gen>.<id>.flam3
```

`<id>` is zero-padded to 5 digits in the filename.

## Fetching / updating

```
make fetch-sheep                 # all generations (idempotent, parallel)
GENS="248" make fetch-sheep      # one generation
PARALLEL=16 make fetch-sheep     # more concurrency
```

The fetcher (`Tools/fetch-sheep-genomes.sh`) is **idempotent**: it skips any
genome already present, so it is safe to re-run to fill gaps or pick up a new
generation. Add a generation by extending `cfg_for` in the script.

> **Infinidream note:** the current `infinidream.ai` REST API
> (`api-alpha.infinidream.ai`) exposes only rendered video — increasingly
> AI-generated — and has **no genome field**. It is not a genome source. Genomes
> for all generations remain on the classic archive hosts above.

## Provenance

- Generations 242-247 were seeded from the
  [`earthbound19/electric_sheep_genomes`](https://github.com/earthbound19/electric_sheep_genomes)
  community backup, then gap-filled directly from the archive servers
  (that backup's gen 247 stops at id 33486; the server still serves sheep up to
  ~44000, which the fetcher recovers).
- Generation 248 (the newest flock) is fetched directly from the server; it is
  not present in any known backup.
- earthbound19's upstream README and curated picks list are kept under
  `electric-sheep/_provenance-earthbound19/`.

## License & attribution

Classic Electric Sheep genomes are released under:
- **CC-BY** (attribution) for human-designed genomes, and
- **CC-BY-NC** (attribution, noncommercial) for robot/"brood"-designed genomes.

Both are compatible with Emberweft's source-available PolyForm Noncommercial
posture and the CC-BY-NC seed library. "Gold" sheep are the **same genome** as a
standard sheep, only rendered at higher resolution historically — there is no
separate license restriction on the genome itself.

The fractal flame algorithm was created by **Scott Draves** in 1992; "Electric
Sheep" and "Infinidream" are trademarks of Scott Draves / e-dream, inc. This
genome collection is an independent archive of community-submitted `.flam3`
files, not affiliated with or endorsed by the Electric Sheep / Infinidream
project.

## Relation to Emberweft

This library is the raw material for the M4 **seed library** (a curated,
hand/render-picked "best" set). The full archive lives here; a curated subset
will be promoted to `curated/` and surfaced in the app.
