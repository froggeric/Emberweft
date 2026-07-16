# Emberweft — convenience wrappers around SwiftPM.
# Real targets land in later milestones (golden/parity/perf/format); see docs/engineering/testing.md.

SWIFT   := swift

.PHONY: build release test run cli clean format lint bootstrap-oracle regen-goldens fetch-sheep help

build:        ## Build (debug)
	$(SWIFT) build

release:      ## Build (release)
	$(SWIFT) build -c release

test:         ## Run tests
	$(SWIFT) test

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

clean:        ## Remove build artifacts
	$(SWIFT) package clean
	rm -rf .build

help:         ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

.DEFAULT_GOAL := help
