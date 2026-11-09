#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
cd "$WORKDIR"

LATEST=$(curl -sSL https://api.github.com/repos/coolapso/agent-skills-validator/releases/latest | python3 -c "import sys,json; print(json.load(sys.stdin)['tag_name'].lstrip('v'))")
ARCHIVE="agent-skills-validator_${LATEST}_linux_amd64.tar.gz"
URL="https://github.com/coolapso/agent-skills-validator/releases/download/v${LATEST}/${ARCHIVE}"
CHECKSUMS_URL="https://github.com/coolapso/agent-skills-validator/releases/download/v${LATEST}/checksums.txt"

curl -sSL --retry 3 --retry-delay 2 -o "$ARCHIVE" "$URL"
curl -sSL --retry 3 --retry-delay 2 -o checksums.txt "$CHECKSUMS_URL"
grep " ${ARCHIVE}\$" checksums.txt | sha256sum -c -

tar -xzf "$ARCHIVE"
BIN="$WORKDIR/agent-skills-validator"

SKILL_DIRS=()
while IFS= read -r -d '' f; do
  SKILL_DIRS+=("$(dirname "$f")")
done < <(find "$REPO_ROOT/skills" -name SKILL.md -print0)

if [ "${#SKILL_DIRS[@]}" -eq 0 ]; then
  echo "No SKILL.md files found" >&2
  exit 1
fi

exec "$BIN" validate "${SKILL_DIRS[@]}"