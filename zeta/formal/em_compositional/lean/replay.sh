#!/bin/sh
# Replay the main theorems of MagnitudeCompare.lean with the checkers that ship
# in the pinned toolchain. Exits non-zero unless every listed theorem was
# exported and both checkers accepted the export.
#
#     sh formal/em_compositional/lean/replay.sh
set -eu
cd "$(dirname "$0")"
theorems="Zeta.rtl_below_bits_exact Zeta.rtl_below_bits_sound Zeta.z64_below_bits_exact Zeta.z64_below_bits_sound"

lean_bin="$(lean --print-prefix)/bin"
for tool in leanexport lean4lean leanchecker-paranoid; do
  if [ ! -x "$lean_bin/$tool" ]; then
    echo "replay: $lean_bin/$tool is missing from this toolchain" >&2
    exit 1
  fi
done
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

lake build
# leanexport exits 0 for an unknown name and only reports it on stderr.
lake env "$lean_bin/leanexport" MagnitudeCompare -- $theorems \
  > "$work/export.ndjson" 2> "$work/export.err"
if [ -s "$work/export.err" ]; then
  cat "$work/export.err" >&2
  echo "replay: leanexport reported a problem" >&2
  exit 1
fi
for theorem in $theorems; do
  if ! grep -q "\"str\":\"${theorem##*.}\"}}\$" "$work/export.ndjson"; then
    echo "replay: $theorem is not in the export" >&2
    exit 1
  fi
done
# The checkers also exit 0 for an empty export.
checked=$("$lean_bin/lean4lean" --import "$work/export.ndjson")
echo "lean4lean: $checked"
case $checked in
  "checked 0 declarations" | "")
    echo "replay: nothing was checked" >&2
    exit 1
    ;;
esac
"$lean_bin/leanchecker-paranoid" --from-export "$work/export.ndjson"
echo "replay: $theorems accepted"
