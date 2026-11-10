#!/usr/bin/env bash
# Rebuilds the patch from a pristine Questie folder and a patched one.
# Usage: scripts/make-patch.sh <pristine-Questie> <patched-Questie>
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
PRISTINE="$1"; PATCHED="$2"
FILES=(Questie_Forever.toc Questie_Camelot.toc Modules/Tracker/QuestieTracker.lua Modules/Tracker/TrackerGamepad.lua Localization/Translations/TrackerUI.lua)
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/a" "$WORK/b"
for f in "${FILES[@]}"; do
  mkdir -p "$WORK/a/$(dirname "$f")" "$WORK/b/$(dirname "$f")"
  [ -f "$PRISTINE/$f" ] && cp "$PRISTINE/$f" "$WORK/a/$f"
  [ -f "$PATCHED/$f" ] && cp "$PATCHED/$f" "$WORK/b/$f"
done
( cd "$WORK" && git diff --no-index --no-color --no-prefix a b > "$HERE/questie-forever-gamepad-tracker.patch" ) || true
cp "$PATCHED/Modules/Tracker/TrackerGamepad.lua" "$HERE/files/Modules/Tracker/TrackerGamepad.lua"
luajit -bl "$HERE/files/Modules/Tracker/TrackerGamepad.lua" > /dev/null && echo "syntax OK"
grep '^diff --git' "$HERE/questie-forever-gamepad-tracker.patch"
