#!/usr/bin/env bash
# Print Core's Supervisor-integration surface at a tag, as the JSON shape
# apps/vagus/test/fixtures/core-<tag>-hassio-views.json holds: every view URL
# its hassio integration registers, plus every WS command type it registers.
#
# Both the fixture and .github/workflows/core-contract-drift.yml run THIS
# script, so a regeneration can never disagree with the check that demanded it.
#
#   scripts/core-hassio-surface.sh 2026.8.1
#
# Downloads the sources; core_hassio_surface.py does the extraction (by AST —
# see its docstring for why, and for why it filters nothing).
set -euo pipefail

TAG="${1:?usage: core-hassio-surface.sh <core-tag>}"
RAW="https://raw.githubusercontent.com/home-assistant/core/${TAG}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(mktemp -d)"
trap 'rm -rf "$SRC"' EXIT

gh api "repos/home-assistant/core/git/trees/${TAG}?recursive=1" --jq '.tree[].path' \
  | grep -E '^homeassistant/components/hassio/.*\.py$' \
  | while read -r path; do
      curl -sfL "${RAW}/${path}" -o "${SRC}/$(basename "$path")"
    done

# A tag whose tree we could not read leaves an empty dir; failing here beats
# emitting an empty surface that reads as "Core registers nothing".
if ! compgen -G "${SRC}/*.py" > /dev/null; then
  echo "no hassio sources fetched for tag ${TAG}" >&2
  exit 1
fi

python3 "${HERE}/core_hassio_surface.py" "$SRC" "$TAG"
