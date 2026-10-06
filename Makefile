SHELL := /bin/bash

DEV_CACHE    ?= $(HOME)/.cache/llm-kit-dev
SHELLCHECK   ?= $(shell command -v shellcheck 2>/dev/null || echo $(DEV_CACHE)/tools/bin/shellcheck)
PODMAN       ?= podman
BASH32_IMAGE ?= docker.io/library/bash:3.2

# Scripts that ship. Both must stay bash-3.2 compatible.
SCRIPTS     := setup.sh llm-kit.sh
SHELL_FILES := $(SCRIPTS) $(wildcard tests/*.sh tests/lib/*.sh tests/*/*_test.sh tests/*/*/*_test.sh spike/*.sh eval/*.sh)
# Test files that must also pass under bash 3.2 + busybox (no jq, no network).
BASH32_TESTS ?= $(wildcard tests/contracts/*_test.sh tests/llm-kit/*_test.sh)

.PHONY: help check lint test test-bash32

help:
	@echo "make check        lint + test + test-bash32"
	@echo "make lint         shellcheck, bash-3.2 construct scan, bash 3.2 syntax check"
	@echo "make test         run the test suite with the system bash"
	@echo "make test-bash32  run host-side tests in the $(BASH32_IMAGE) container"

check: lint test test-bash32

lint:
	$(SHELLCHECK) --severity=warning $(SHELL_FILES)
	bash tests/lib/check-bash32.sh $(SCRIPTS)
	$(PODMAN) run --rm --network=none -v "$(CURDIR)":/w:ro $(BASH32_IMAGE) \
	  bash -c 'for f in $(SHELL_FILES); do bash -n /w/$$f || exit 1; done'

test:
	bash tests/run.sh

test-bash32:
	$(PODMAN) run --rm --network=none -v "$(CURDIR)":/w:ro -w /w $(BASH32_IMAGE) \
	  bash tests/run.sh $(BASH32_TESTS)
