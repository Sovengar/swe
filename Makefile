# swe lives in this repo and is used through PATH: no target requires you to
# cd here. `make install` only puts a symlink on PATH, so edits here are live.

PREFIX  ?= $(HOME)/.local
BINDIR  ?= $(PREFIX)/bin
SWE     := $(CURDIR)/swe.sh

TESTS   := tests/contract.sh tests/lifecycle.sh tests/change.sh tests/publish-guards.sh

.PHONY: help install uninstall test lint check

help:
	@printf '%s\n' \
	  'make install       symlink swe into $(BINDIR)' \
	  'make uninstall     remove that symlink' \
	  'make test          run the behaviour tests' \
	  'make lint          shellcheck every script' \
	  'make check         parse every script (bash -n)'

install:
	@mkdir -p "$(BINDIR)"
	ln -sfn "$(SWE)" "$(BINDIR)/swe"
	@printf 'installed %s -> %s\n' "$(BINDIR)/swe" "$(SWE)"

uninstall:
	@if [ -L "$(BINDIR)/swe" ]; then rm -f "$(BINDIR)/swe" && printf 'removed %s\n' "$(BINDIR)/swe"; fi

test:
	@bash tests/run-all.sh

lint:
	@command -v shellcheck >/dev/null 2>&1 || { printf 'shellcheck not installed\n' >&2; exit 1; }
	shellcheck -s bash swe.sh isolation.sh swe-pipeline.sh lib/*.sh lib/change/*.sh lib/change/mechanism/*.sh
	shellcheck -s bash -S warning tests/*.sh

check:
	@set -e; for f in swe.sh isolation.sh swe-pipeline.sh lib/*.sh lib/change/*.sh lib/change/mechanism/*.sh tests/*.sh; do bash -n "$$f"; done; \
	printf 'parse ok\n'
