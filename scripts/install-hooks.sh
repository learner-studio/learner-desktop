#!/usr/bin/env bash
# Points git at the repo's hooks: pre-commit = light lane, pre-push = medium + heavy.
cd "$(dirname "$0")/.." && git config core.hooksPath .githooks && echo "hooks installed (.githooks)"
