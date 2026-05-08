#!/usr/bin/env bash
# Run this once after cloning to install git hooks.
set -e
cp .githooks/pre-commit .git/hooks/pre-commit
chmod +x .git/hooks/pre-commit
echo "Hooks installed."
