# Seed Library

*A curated collection of high-quality flame genomes for playback, export, and breeding.*

> **Status:** preliminary — for review · Emberweft

## Purpose

The seed library is a hand-curated set of appealing flame genomes that serve as the foundation for user exploration in Emberweft. Unlike the distributed flock of the original Electric Sheep, this library is entirely standalone — a local collection of "good sheep" carefully selected for visual quality, diversity, and licensing compatibility.

The seed library enables users to:
- Browse and preview genomes as an alternative to random generation
- Start from polished genomes for breeding and mutation experiments
- Export genomes with confidence in their visual quality and licensing status
- Build personal collections through bookmarking and custom playlists

## Storage Layout

The seed library resides in an app-group container, shared between the main application and the screensaver bundle. This ensures both the standalone app and the screensaver can access the same library without duplication.

**Default location (preliminary):**
```
~/Library/Group Containers/group.tbd.«project».app/Library/
├── SeedLibrary/
│   ├── manifest.json
│   ├── thumbnails/
│   │   ├── 001a2b3c4d5e.png
│   │   └── ...
│   └── genomes/
│       ├── 001a2b3c4d5e.flam3
│       └── ...
```

The app-group container pattern ensures the screensaver (running as a separate process) can read the same seed library that users manage through the main app. See [`../platform/screensaver.md`](../platform/screensaver.md) for screensaver integration details.

## Metadata Schema

The `manifest.json` file indexes all genomes in the library with rich metadata for browsing, search, and filtering. Each entry includes:

```json
{
  "version": "1.0",
  "genomes": [
    {
      "id": "001a2b3c4d5e6f7g8h9i0jkl",
      "title": "Nebula Cascade",
      "author": "Scott Draves",
      "source": "Original Electric Sheep flock #2441",
      "license": "CC-BY-SA 4.0",
      "tags": ["cosmic", "symmetric", "gradient", "detailed"],
      "rating": 5,
      "duration": 30,
      "palette_swatch": ["#1a0b2e", "#4a1c40", "#8b3a62", "#d65a78"],
      "thumbnail_path": "thumbnails/001a2b3c4d5e.png",
      "genome_path": "genomes/001a2b3c4d5e.flam3",
      "suitable_for": ["landscape", "desktop", "vertical"],
      "quality_hint": "high",
      "imported_at": "2025-01-15T10:30:00Z",
      "checksum": "sha256:a1b2c3d4e5f6..."
    }
  ]
}
```

**Field descriptions:**
- `id`: Stable UUID-based identifier for the genome, unchanged by re-imports
- `title`: Human-readable name for display in UI
- `author`: Original creator of the genome
- `source`: Origin or attribution string (e.g., original flock ID, creator name)
- `license`: SPDX identifier or free-text license; must permit redistribution
- `tags`: Array of descriptive keywords for filtering (visual style, mood, characteristics)
- `rating`: User-assigned quality score 0–5 (0 = unrated)
- `duration`: Suggested playback duration in seconds **(preliminary: 30–60s)**
- `palette_swatch`: 4–6 representative hex colors for UI preview
- `thumbnail_path`: Relative path to rendered thumbnail image
- `genome_path`: Relative path to the `.flam3` genome file
- `suitable_for`: Array of aspect ratios (landscape, square, vertical)
- `quality_hint`: Rendering quality hint (low/medium/high) for performance scaling
- `imported_at`: ISO 8601 timestamp when added to library
- `checksum`: SHA-256 hash of the genome file for integrity verification

See [`../rendering/genome-format.md`](../rendering/genome-format.md) for the `.flam3` file specification.

## Import

### Manual Import

Users can add genomes to the seed library through:
- **Drag-and-drop**: Dropping `.flam3` files onto the library browser
- **Batch import**: Selecting a folder to import all contained `.flam3` files
- **Menu import**: File → Import Genome(s) from the app menu

During import:
1. The `.flam3` file is parsed for validation
2. A low-sample thumbnail is rendered using the Metal pipeline **(preliminary: 1000 samples)**
3. A unique ID is generated based on file content hash
4. Metadata is extracted from the genome (author, title if present)
5. The user can review/edit metadata before confirming import
6. The genome is written to `genomes/` and the manifest updated

### Electric Sheep Flock Import (Future/Optional)

Emberweft may optionally support importing genomes from the original Electric Sheep / Infinidream flock. This feature would:
- Parse flock metadata files if present
- Preserve attribution and licensing information
- Clearly mark the source as the original distributed flock
- Require explicit user action (no automatic network fetching)

This is explicitly **not** a dependency for MVP and may be omitted entirely. The seed library is designed to function as a standalone curated collection.

## Thumbnail Generation

Thumbnails are generated at import time using the same Metal rendering pipeline as realtime playback. A low-sample render produces a representative still image for browsing:

**Thumbnail rendering parameters (preliminary):**
- Resolution: 640×360 (16:9) or equivalent for other aspect ratios
- Samples: 1000 chaos-game iterations per pixel
- Quality tier: Medium (balanced quality/speed)
- Output: PNG with alpha channel (for transparency effects)

The thumbnail renderer reuses the compute pipeline from [`../rendering/metal-pipeline.md`](../rendering/metal-pipeline.md) but with fixed, conservative parameters suitable for batch processing. Thumbnails are regenerated on-demand if the rendering algorithm changes significantly.

## Search and Filtering

The library browser provides rich search and filtering capabilities:

**Filter dimensions:**
- **Tags**: Select genomes by visual style (cosmic, organic, geometric, abstract)
- **Rating**: Show only 4+ star genomes, or sort by rating
- **Palette**: Filter by dominant color or color scheme
- **Aspect suitability**: Show only genomes suitable for vertical displays
- **Quality**: Filter by rendering quality hint
- **Author**: Browse by creator

**Smart playlists:**
- "Favorites": User-bookmarked genomes (rating 4+ stars)
- "Recent": Added in the past 30 days
- "Vertical-optimized": Best suited for vertical/social formats
- "High-detail": Genomes tagged as "detailed" with high quality hint
- "Experimental": Genomes with uncommon variation combinations

Search and filtering are performed entirely client-side with no network dependency.

## Sync and Sharing (Future)

Future versions may support exporting curated collections:

**Export pack:**
- Export selected genomes as a zip file
- Include manifest, genomes, and thumbnails
- Option to include rendered video clips
- Preserve all metadata and licensing information

**Import pack:**
- Import a previously exported pack
- Merge with existing library, handling ID conflicts
- Option to import to a separate "collection" folder

This feature enables users to share their favorite genomes with others while maintaining attribution and licensing metadata.

## Curation Policy

The seed library only includes genomes whose licenses explicitly permit redistribution. All genomes must:

1. **Allow redistribution**: The license must permit sharing the genome file
2. **Preserve attribution**: Author and source information must be retained
3. **Be compatible with commercial use**: For inclusion in a commercial product

Supported licenses include:
- Creative Commons (CC-BY, CC-BY-SA, CC0)
- Permissive open licenses (MIT, Apache 2.0, BSD)
- Explicit permission from the author

Genomes with unclear licensing, all-rights-reserved, or from proprietary sources are excluded from the seed library. Users may still manually import such genomes for personal use, but they won't be included in the default distributed library.

## Performance Considerations

**Library size limits (preliminary):**
- Default library: 50–100 genomes (approx. 50–100 MB total)
- Maximum recommended: 1000 genomes (approx. 500 MB – 1 GB)
- Thumbnail cache: Scaled proportionally to library size

The library browser uses lazy loading and virtual scrolling to handle large libraries efficiently. Thumbnails are loaded on-demand and cached in memory.

**I/O patterns:**
- Manifest read once at startup
- Thumbnails loaded incrementally during scrolling
- Genome files loaded only when playing or exporting
- Writes only occur during import or rating updates

## Related Documentation

- [`../rendering/genome-format.md`](../rendering/genome-format.md) — `.flam3` file specification
- [`../rendering/metal-pipeline.md`](../rendering/metal-pipeline.md) — Thumbnail rendering pipeline
- [`../platform/screensaver.md`](../platform/screensaver.md) — Screensaver library access
- [`genetics.md`](genetics.md) — Breeding and mutation features

---

**Credit**: fractal flame algorithm © Scott Draves (1992). Electric Sheep™ and Infinidream™ are trademarks of Scott Draves / e-dream, inc.
