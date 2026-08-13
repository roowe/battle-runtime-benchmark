#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")" && pwd)"
JAVAC_BIN="${JAVA_HOME:+$JAVA_HOME/bin/javac}"
if [[ -z "${JAVAC_BIN}" || ! -x "${JAVAC_BIN}" ]]; then
  if [[ -x /opt/homebrew/opt/openjdk@25/bin/javac ]]; then
    JAVAC_BIN=/opt/homebrew/opt/openjdk@25/bin/javac
  else
    JAVAC_BIN=javac
  fi
fi
mkdir -p "$root/out"
"$JAVAC_BIN" --release 25 -d "$root/out" "$root/Sim.java" "$root/Main.java"
