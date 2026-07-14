# Genetics

*Local genetic algorithm for evolving flame genomes through mutation, crossover, and selection.*

> **Status:** preliminary — for review · Emberweft

> **POST-MVP FEATURE**: The genetic algorithm system is planned for a later milestone after the core rendering and playback features are complete. This document outlines the intended design; implementation timing is to be determined.

## Overview

Emberweft includes an optional local genetic algorithm that allows users to evolve new flame genomes through mutation, crossover (breeding), and selection. Unlike the original Electric Sheep's distributed, server-coordinated evolution, this system runs entirely on the user's machine — a single-user "micro-evolution" engine.

The genetic features are entirely local with no network dependency. Users generate, mutate, and breed genomes on their own machine, building personal lineages of interesting sheep. The "evolution" happens through guided experimentation rather than distributed computation.

**Key principles:**
- **Local-only**: No server, no shared flock, no network communication
- **User-guided**: Selection based on explicit user voting/bookmarks, not implicit preferences
- **Transparent**: Lineage and mutation history visible to the user
- **Optional**: Can be disabled via settings; not required for core functionality

This approach contrasts with the original Electric Sheep, where evolution emerged from the collective preferences of thousands of users contributing to a shared gene pool. In Emberweft, evolution is a personal creative tool.

## Genetic Operations

### Random Genome Generation

Generate entirely new genomes from scratch using random parameters:

**Randomization parameters:**
- **Transform count**: 2–6 transforms **(preliminary)**
- **Affine coefficients**: Random values in typical range [-2, 2]
- **Variation weights**: Random selection of 3–5 variations per transform with random weights
- **Palette**: Random from built-in palette library
- **Color indices**: Random assignment across transforms
- **Final transform**: 50% chance of inclusion

The random generator uses constrained randomization to avoid producing fundamentally broken genomes:
- Prevent degenerate transforms (zero coefficients, zero variation weights)
- Ensure reasonable spatial coverage (center point not too far from origin)
- Limit extreme variation weights that cause visual artifacts

### Mutation

Mutate an existing genome by perturbing its parameters:

**Mutation types:**
1. **Coefficient mutation**: Randomly perturb affine coefficients by ±10% **(preliminary)**
2. **Variation weight mutation**: Adjust variation weights by ±25% or add small weight to a previously-unused variation
3. **Palette shift**: Swap to a similar or complementary palette
4. **Transform addition**: Add a new transform with random parameters
5. **Transform removal**: Remove a non-essential transform (if count > 2)
6. **Color remix**: Reassign color indices across transforms

Mutation strength is user-configurable:
- **Subtle**: Small perturbations, preserving character
- **Moderate**: Balanced changes **(default)**
- **Radical**: Large parameter changes, high chance of transform addition/removal

The mutation operator randomly selects 1–3 mutation types per operation, creating incremental variations on the parent genome.

### Crossover (Breeding)

Combine two parent genomes to create offspring that blend characteristics from both:

**Crossover method:**
The crossover reuses the genome interpolation system from [`../rendering/transitions.md`](../rendering/transitions.md). A crossover is essentially a 50/50 weighted blend between two genomes:

```
offspring = blend(parentA, parentB, t=0.5)
```

**Blend parameters:**
- **Transform count**: Max of parent counts (empty transforms added to match)
- **Affine coefficients**: Linear interpolation of coefficient matrices
- **Variation weights**: Averaged across matching transforms
- **Palette**: Randomly selected from either parent or a blend
- **Color speed**: Blended from both parents

The crossover produces a single child genome that exhibits characteristics from both parents. Users can then iteratively breed children with each other or with new parents to explore the combinatorial space.

**Advanced crossover (future):**
- **Multi-parent blending**: Blend 3+ parents with weighted contributions
- **Transform-wise mixing**: Use different transforms from different parents (not just interpolation)
- **Asymmetric blending**: 70/30 or 80/20 splits for parent dominance

## Fitness and Selection

In the original Electric Sheep, fitness emerged implicitly from user votes across the distributed flock. Emberweft uses explicit user actions to assign fitness:

**Fitness indicators:**
- **Bookmark/thumb-up**: User marks a genome as a favorite (fitness = +1)
- **Export**: User exports a genome to video (fitness = +0.5)
- **Playback duration**: Longer watch time correlates with fitness (tracked silently)
- **Manual rating**: User assigns 1–5 star rating

Fitness scores are maintained per-genome in the seed library manifest. The genetic algorithm uses fitness to:
- Suggest genomes for breeding ("breed your two favorites")
- Prioritize which genomes to mutate ("mutate from high-fitness parents")
- Display lineages showing the "family tree" of evolved genomes

**Important**: Fitness is purely local to the user's library. There is no global ranking or shared fitness function.

## Lineage and History

Each genome tracks its genetic history:

**Lineage metadata:**
```json
{
  "id": "...",
  "parents": ["parent-id-a", "parent-id-b"],
  "operation": "crossover",
  "created_at": "2025-02-01T15:30:00Z",
  "generation": 3
}
```

- `parents`: Array of parent genome IDs (empty for randomly-generated genomes)
- `operation`: Type of operation (random, mutation, crossover)
- `created_at`: When this genome was created
- `generation`: Number of generations from random ancestors (0 = random)

The **Lineage View** displays this history as a tree, showing how genomes relate to each other. Users can explore:
- The family tree of a genome (parents, grandparents, children)
- All descendants of a particular genome
- The evolutionary path from a random ancestor to a polished result

This lineage tracking helps users understand how their experiments evolved and return to promising branches.

## UI Integration

Genetic features are integrated into the main app UI:

**Library browser:**
- "Random" button: Generate a new random genome
- "Mutate" button: Create variants of selected genome(s)
- "Breed" mode: Select two genomes and breed them
- "Lineage" button: View family tree of selected genome

**Genetic workspace (dedicated panel):**
- Split view showing parent(s) and offspring side-by-side
- Controls for mutation strength and type
- Playback preview of offspring
- Save/promote offspring to seed library
- Discard and retry

**Settings:**
- Enable/disable genetic features entirely
- Default mutation strength
- Whether to auto-save all experiments vs. requiring explicit save
- Maximum lineage depth to track **(preliminary: 10 generations)**

The genetic workspace is designed for experimentation: users can rapidly try many variations and promote only the best results to their main library.

## Relationship to Rendering Pipeline

The genetic system heavily reuses components from the rendering pipeline:

**Shared components:**
- **Genome model**: The same [`FlameGenome`](../rendering/genome-format.md) structure is used throughout
- **Interpolation**: Crossover uses the [`blend`](../rendering/transitions.md) function from transitions
- **Validation**: Mutated genomes pass the same validation as imported genomes
- **Rendering**: All genetic experiments are previewable through the standard Metal pipeline

This reuse ensures that any genome generated genetically is immediately playable and exportable — no special handling required.

## Local vs. Distributed Evolution

The original Electric Sheep's defining feature was its distributed genetic algorithm, where thousands of users contributed to a shared evolutionary process. Emberweft takes a different approach:

| Aspect | Electric Sheep (original) | Emberweft (local genetics) |
|--------|--------------------------|---------------------------|
| Gene pool | Shared server flock | Personal library only |
| Selection | Implicit (users vote on frames they like) | Explicit (bookmark, breed, mutate) |
| Coordination | Server-mediated | None |
| Network | Required for full experience | Optional; genetic features work offline |
| Evolution | Emergent from crowd | Directed by individual |
| Lineage | Global, anonymous | Personal, tracked |

The local approach prioritizes:
- **Privacy**: No data leaves the user's machine
- **Reliability**: No network dependencies
- **Agency**: User has full control over evolutionary direction
- **Simplicity**: No server infrastructure, authentication, or data synchronization

Users who want the social/flocking experience can still participate in the original Electric Sheep project. Emberweft offers genetics as a creative tool, not a social platform.

## Performance and Resource Impact

Genetic operations are relatively lightweight:

**Operation costs:**
- **Random generation**: ~1ms CPU (parameter generation only)
- **Mutation**: ~1ms CPU (parameter perturbation)
- **Crossover**: ~2ms CPU (genome interpolation)
- **Preview rendering**: Same cost as normal playback (GPU-bound)

The main resource cost is rendering previews for user experiments. The system caps the number of simultaneous experiments:
- **Max concurrent experiments**: 3 **(preliminary)**
- **Preview resolution**: 720p maximum (regardless of output setting)
- **Preview quality**: Medium tier (balanced speed/quality)

## Future Enhancements

Potential improvements to the genetic system (not planned for initial release):

**Advanced operators:**
- **Speciation**: Group genomes by similarity and breed within species
- **Fitness prediction**: ML model to predict user preference from parameters
- **Automated evolution**: Run genetic algorithm overnight to generate candidate genomes

**Social features (if network is ever added):**
- **Lineage sharing**: Export/import of family trees
- **Collaborative breeding**: Share genomes with lineage metadata for others to extend
- **Genetic challenges**: "Create offspring of these two parents" as a creative prompt

**Analytics:**
- **Evolution visualization**: Animated evolution of a genome over generations
- **Success metrics**: Track which mutation types lead to highest-rated offspring
- **Parameter importance**: Identify which parameters most affect user preference

These are explicitly exploratory and may never be implemented.

## Related Documentation

- [`../rendering/genome-format.md`](../rendering/genome-format.md) — Genome data structure
- [`../rendering/transitions.md`](../rendering/transitions.md) — Interpolation for crossover
- [`../platform/app-ui.md`](../platform/app-ui.md) — UI integration points

---

**Credit**: fractal flame algorithm © Scott Draves (1992). Electric Sheep™ and Infinidream™ are trademarks of Scott Draves / e-dream, inc.
