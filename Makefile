# Emberweft — convenience wrappers around SwiftPM.
# Real targets land in later milestones (golden/parity/perf/format); see docs/engineering/testing.md.

SWIFT   := swift

.PHONY: build release dist test test-fast test-parity test-perf run cli clean format lint bootstrap-oracle regen-goldens fetch-sheep sync-sheep feature-cache help

build:        ## Build (debug)
	$(SWIFT) build

release:      ## Build (release)
	$(SWIFT) build -c release

# Version stamped into Emberweft.app's Info.plist (CFBundleShortVersionString /
# CFBundleVersion): the nearest git tag with its leading "v" stripped (e.g. 0.5.7),
# or 0.0.0 on a tag-less checkout. Override for a bespoke build: make dist APP_VERSION=1.2.3
GIT_TAG := $(shell git describe --tags --abbrev=0 2>/dev/null || echo 0.0.0)
APP_VERSION ?= $(patsubst v%,%,$(GIT_TAG))

APP_BUNDLE := dist/Emberweft.app

dist: release ## Build a distributable into ./dist: Emberweft.app (double-clickable GUI) + the emberweft CLI beside its Metal bundle. Gitignored — reproducible via this target.
	@rm -rf dist
	@mkdir -p $(APP_BUNDLE)/Contents/MacOS $(APP_BUNDLE)/Contents/Resources
	@sed 's/__APP_VERSION__/$(APP_VERSION)/' Tools/dist/Emberweft-Info.plist > $(APP_BUNDLE)/Contents/Info.plist
	cp .build/release/emberweft dist/
	cp -R .build/release/emberweft_FlameRenderer.bundle dist/
	cp .build/release/emberweft-gui $(APP_BUNDLE)/Contents/MacOS/
	# Standard Contents/Resources placement (Bundle.main.resourceURL). SwiftPM 6's generated
	# Bundle.module accessor does NOT search it (only the .app root — where codesign rejects
	# foreign entries — and the build machine's .build path), which is why the sources resolve
	# it explicitly: FlameRenderer/ModuleResources.swift + EmberweftGUI/AppModel.moduleBundle.
	cp -R .build/release/emberweft_FlameRenderer.bundle .build/release/emberweft_EmberweftGUI.bundle $(APP_BUNDLE)/Contents/Resources/
	@xattr -cr $(APP_BUNDLE)
	@codesign --force --deep --sign - $(APP_BUNDLE)
	@echo "Release built into dist/:"
	@echo "  Emberweft.app — double-click it, or: open dist/Emberweft.app   (no Terminal window)"
	@echo "  emberweft     — CLI; run it from dist/ so the sibling emberweft_FlameRenderer.bundle resolves (--backend metal)"

test:         ## Run the full pre-merge suite (fast + parity; ~12 min). Excludes the opt-in perf gate — use `make test-perf`.
	$(SWIFT) test --filter FlameKitTests --filter EmberweftCLITests --filter FlamePlayerTests --filter FlameReferenceTests --filter FlameRendererTests

test-fast:    ## Mechanics + CLI + engine units (no Metal, no oracle; ~2 s)
	$(SWIFT) test --filter FlameKitTests --filter EmberweftCLITests --filter FlamePlayerTests

test-parity:  ## vs-flam3 + Metal↔CPU parity (heavy; ~12 min). Needs the flam3 oracle on $$PATH for the vs-flam3 rows (else they skip).
	$(SWIFT) test --filter FlameReferenceTests --filter FlameRendererTests

test-perf:    ## Realtime capability gate (≥58 fps @1080p). OPT-IN: release build, Metal device, bash sandbox OFF.
	EMBERWEFT_PERF=1 $(SWIFT) test -c release --filter RealtimeCapabilityTests

run: cli
cli:          ## Run the emberweft CLI (no args = help)
	$(SWIFT) run emberweft

format:       ## Format sources with swift-format
	swift format --in-place --recursive Sources Tests

lint:         ## Lint sources with swift-format
	swift format lint --recursive Sources Tests

bootstrap-oracle:  ## Build dev-only GPL flam3 oracle from source into $(HOME)/flam3-oracle
	@echo "Building dev-only flam3 oracle (GPL) from source into $$HOME/flam3-oracle"
	@echo "  -> strict-IEEE build (no -ffast-math) for reproducible parity."
	@mkdir -p "$$HOME/flam3-oracle-src" && cd "$$HOME/flam3-oracle-src" && \
	  git clone --depth 1 https://github.com/scottdraves/flam3.git && \
	  cd flam3 && \
	  CPPFLAGS="-I$$(brew --prefix)/include" LDFLAGS="-L$$(brew --prefix)/lib" \
	  ./configure --prefix="$$HOME/flam3-oracle" && \
	  make -j8 AM_CFLAGS="" CFLAGS="-O2 -g" && make install
	@echo "Done. flam3-render is at $$HOME/flam3-oracle/bin/flam3-render (dev-only; never linked/bundled)."

regen-goldens:                      ## (dev) regenerate flam3 golden reference PNGs
	bash Tools/regen_goldens.sh

fetch-sheep:                        ## Fetch Electric Sheep .flam3 genomes into genomes/
	bash Tools/fetch-sheep-genomes.sh

sync-sheep:                         ## Sync NEW genomes from the live flock (gen 248)
	bash Tools/sync-live-flock.sh

feature-cache:                      ## Rebuild the genomes/.feature_cache/ feature-vector cache
	$(SWIFT) run emberweft --rebuild-cache genomes

clean:        ## Remove build artifacts
	$(SWIFT) package clean
	rm -rf .build

help:         ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

.DEFAULT_GOAL := help
