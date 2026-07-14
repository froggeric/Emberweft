# Contributing to Emberweft

Thanks for your interest in Emberweft! This project is **source-available under the PolyForm Noncommercial License 1.0.0** — free to read, use, modify, and redistribute for noncommercial purposes. Commercial use requires a separate commercial license. See [LICENSE](LICENSE) and [docs/license-and-attribution.md](docs/license-and-attribution.md).

## Before you contribute: CLA required

Because Emberweft is noncommercial-licensed, **every external contribution must be covered by a Contributor License Agreement (CLA).** The CLA grants the maintainer the commercial rights to your contribution so the project's commercial option stays intact. Without it, your contribution's noncommercial restriction would stick to your changes and block the maintainer's own commercial use.

- **Solo-authored code (now):** no CLA needed.
- **The moment the first external pull request is accepted:** a CLA will be required and acknowledged before merge.

> Until the CLA text is finalized, please open an issue to discuss significant changes before starting work — we want to avoid wasted effort.

## How to contribute

1. **Open an issue first** for anything beyond a trivial fix — discuss scope and approach.
2. Fork the repo and create a feature branch from `main`.
3. Work test-first (see [docs/engineering/development-approach.md](docs/engineering/development-approach.md) and [docs/engineering/testing.md](docs/engineering/testing.md)).
4. Make small, focused commits using [Conventional Commits](https://www.conventionalcommits.org/) (`feat:`, `fix:`, `test:`, `docs:`, `refactor:`, `perf:`, `chore:`).
5. Ensure `swift build` and `swift test` pass locally.
6. Open a pull request against `main`; CI must be green before merge.

## Code style

- Swift 6, strict concurrency (`Sendable`, actors, no data races).
- Formatted with [swift-format](https://github.com/apple/swift-format) (config in `.swift-format`).
- No external dependencies beyond Apple SDKs unless explicitly approved.

## Project status

Emberweft is **pre-alpha**: this repository currently contains design and specification documents plus a compiling scaffold. Implementation follows the [roadmap](docs/engineering/roadmap.md) (M0 scaffold → M1 CPU reference renderer + CLI → M2 Metal renderer …). The best way to help right now is to review the specs, file issues on the design, or pick a roadmap slice.

## Reporting bugs / requesting features

Open a GitHub issue. For security-sensitive matters, prefer a private channel if available; otherwise a normal issue is fine at this stage.
