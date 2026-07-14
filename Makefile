# Emberweft — convenience wrappers around SwiftPM.
# Real targets land in later milestones (golden/parity/perf/format); see docs/engineering/testing.md.

SWIFT   := swift

.PHONY: build release test run cli clean format lint bootstrap-oracle help

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

bootstrap-oracle:  ## Install dev-only flam3 oracle (Homebrew)
	brew install flam3

clean:        ## Remove build artifacts
	$(SWIFT) package clean
	rm -rf .build

help:         ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

.DEFAULT_GOAL := help
