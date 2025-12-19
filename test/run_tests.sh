#!/usr/bin/env bash
# Run tests for entrypoint.sh
# Requires bats-core: brew install bats-core (macOS) or apt install bats (Linux)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Check if bats is installed
if ! command -v bats &> /dev/null; then
  echo "Error: bats-core is not installed."
  echo "Install with:"
  echo "  macOS:  brew install bats-core"
  echo "  Ubuntu: sudo apt install bats"
  exit 1
fi

echo "Running tests..."
bats "$SCRIPT_DIR/entrypoint.bats"
