# Project Overview

*A comprehensive introduction to Emberweft — vision, audience, and scope.*

> **Status:** preliminary — for review · Emberweft

## Purpose & Vision

Emberweft aims to bring the fractal flame algorithm to modern macOS hardware through a native, GPU-accelerated implementation that serves multiple creative workflows. It is both a practical tool — for generating video, creating visuals, and running screensavers — and a technical exploration of how generative art algorithms can leverage contemporary Apple Silicon architecture.

The vision is a unified application that bridges the gap between technical users who want to control parameters and casual users who want beautiful, ever-changing visuals. By real-time rendering directly on Metal, we enable interactive audio-reactive experiences that weren't feasible with CPU-bound renderers, while also providing batch export for production workflows.

## Target Audience

- **Generative artists and VJs** who need real-time visuals and audio-reactive rendering for live performances
- **Musicians and producers** who want to create music videos with generative, beat-synchronized visuals
- **Screensaver enthusiasts** who appreciate ambient, ever-evolving art on their idle displays
- **Developers and graphics programmers** interested in GPU compute, Metal shaders, and generative algorithms
- **Archivists and preservationists** documenting the history of generative art and distributed computing projects

## Core Differentiator

Emberweft is the **only native Swift/Metal implementation** of the fractal flame algorithm that includes a complete video pipeline — playback, export, screensaver, and music-video modes — in a single macOS-native application.

While other implementations exist (flam3 in C, Fractorium in C++/Qt, various shader toys), they either require cross-platform abstraction layers, lack integrated export/playback, or are not optimized for Apple Silicon specifically. By being native to the platform, we can leverage unified memory, Metal's compute shader capabilities, and Swift's concurrency model to achieve real-time performance that cross-platform approaches cannot match — all while being format-compatible with the existing .flam3 ecosystem.

## Feature Pillars

### Generative Rendering
Real-time Metal-accelerated rendering of the [fractal flame algorithm](rendering/flame-algorithm.md) with support for multiple [resolutions](playback/formats.md) and quality presets. See [Metal Pipeline](rendering/metal-pipeline.md).

### Video Pipeline
Complete export workflow with configurable codecs, quality settings, and batch rendering capabilities. See [Export Pipeline](export/export-pipeline.md).

### Audio-Reactive Visuals
Both offline music video rendering and real-time audio-reactive modes that synchronize visuals to beat detection and frequency analysis. See [Music Video](export/music-video.md).

### Screensaver Integration
Native macOS screensaver bundle with seamless integration into System Settings and support for multiple displays. See [Screensaver](platform/screensaver.md).

### Genome Library
Curated collection of high-quality seed genomes with metadata, ratings, and searchable parameters. Includes genetics operations for mutation and evolution. See [Seed Library](library/seed-library.md).

## Non-Goals (MVP Scope)

The following are explicitly **out of scope** for the initial release. These represent scope decisions, not permanent exclusions — some may be reconsidered in future milestones.

- **Distributed render farm:** Unlike the original Electric Sheep, this is a local-only application. No networking, no peer-to-peer contribution, no server communication.
- **Telemetry or analytics:** No data collection, no usage tracking, no crash reporting to external servers.
- **Flame editor:** The initial version will not include a genome editor. Users can import .flam3 files or use the curated library, but visual editing is deferred.
- **Cross-platform support:** macOS-only, Apple Silicon-only (no Intel Macs, no Windows, no Linux). This allows us to specialize deeply on Metal and Apple Silicon.
- **iOS/iPadOS:** While technically possible, mobile platforms add significant UI and performance complexity. May be revisited after desktop maturity.
- **Flock protocol compatibility:** While we read .flam3 genomes, we do not implement the Electric Sheep flock protocol for voting, sharing, or distributed rendering.

These non-goals keep the project focused on delivering a polished, performant macOS experience rather than attempting to be everything at once.

## Relationship to the Ecosystem

Emberweft exists alongside the fractal flame ecosystem rather than within it. We read and write the .flam3 genome format, making us compatible with existing flame editors and genome collections. However, we are:

- **Independent:** Not derived from Electric Sheep or Infinidream source code
- **Unaffiliated:** Not endorsed by or connected to Scott Draves or e-dream, inc.
- **Standalone:** No network connectivity to Electric Sheep servers, no flock protocol
- **Respectful:** We credit and acknowledge the original algorithm and trademarks

We benefit from the existing ecosystem of genome files, tools, and documentation while charting our own direction for how fractal flames can be used on modern hardware.

## How to Read the Docs

For those exploring the project, we recommend this reading order:

1. **Start here:** This overview establishes the project's purpose and scope
2. [Background](background.md) — historical context on fractal flames and Electric Sheep
3. [Architecture](architecture.md) — system design and component relationships
4. [Rendering](rendering/flame-algorithm.md) — the core algorithm and GPU implementation
5. [Playback & Export](playback/playback-modes.md) — how content is consumed and exported
6. [Platform Integration](platform/screensaver.md) — macOS-specific features
7. [Engineering](engineering/tech-stack.md) — technical implementation details

For contributors and developers interested in the code, jump straight to [Tech Stack](engineering/tech-stack.md) and [Project Layout](engineering/project-layout.md).

For visual artists and users, focus on [Playback Modes](playback/playback-modes.md), [Export Pipeline](export/export-pipeline.md), and [Music Video](export/music-video.md).

For everyone: [Glossary](engineering/glossary.md) clarifies domain terminology used throughout the docs.
