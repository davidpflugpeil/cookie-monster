#!/bin/bash
# Hermetic tests for the profile system. Runs against a throwaway home, never your own.
set -euo pipefail
cd "$(dirname "$0")"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
echo "› Building tests (sandbox: $SANDBOX)…"
swiftc -O src/Core.swift tests/main.swift -o "$SANDBOX/tests"
COOKIE_MONSTER_HOME="$SANDBOX" HOME="$SANDBOX" "$SANDBOX/tests"
