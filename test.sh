#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
xcrun swiftc -swift-version 5 -lsqlite3 Sources/HistoryStore.swift Tests/main.swift -o "$TMP/history-tests"
"$TMP/history-tests"
