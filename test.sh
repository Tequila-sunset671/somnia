#!/bin/zsh
# Runs Somnia's pure-logic unit tests. SwiftPM/XCTest don't work under Command
# Line Tools only, so we compile all app sources EXCEPT App.swift (its @main
# would clash with the test's top-level entry) together with tests/main.swift
# into a throwaway executable and run it.
set -e
cd "$(dirname "$0")"

SRC=$(ls Sources/Somnia/*.swift | grep -v '/App.swift$')
BIN="$(mktemp -d)/somnia_tests"

xcrun --sdk macosx swiftc -O -target arm64-apple-macosx14.0 \
  ${(f)SRC} tests/main.swift \
  -o "$BIN" \
  -framework SwiftUI -framework AppKit -framework WebKit -framework Network

"$BIN"
