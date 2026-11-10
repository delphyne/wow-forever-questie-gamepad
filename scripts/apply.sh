#!/usr/bin/env bash
# Applies the patch to a Questie install. Usage: scripts/apply.sh [path-to-Questie-folder] [-R]
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
QUESTIE="${1:-/Applications/World of Warcraft/_forever_/Interface/AddOns/Questie}"
shift || true
cd "$QUESTIE"
patch -p1 --dry-run "$@" < "$HERE/questie-forever-gamepad-tracker.patch"
patch -p1 "$@" < "$HERE/questie-forever-gamepad-tracker.patch"
echo "Done. /reload in game."
