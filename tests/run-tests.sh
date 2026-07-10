#!/usr/bin/env bash
# Run the ERT test suite for beads-worktree-orchestrator.el.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

emacs --batch \
  -l ert \
  -l beads-worktree-orchestrator.el \
  -l tests/beads-worktree-orchestrator-test.el \
  -f ert-run-tests-batch-and-exit
