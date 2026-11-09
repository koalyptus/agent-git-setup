#!/usr/bin/env bash
# Validate all SKILL.md packages against the Agent Skills spec.
# Downloads a pinned agent-skills-validator release (verified by checksum).
set -euo pipefail

VALIDATOR_VERSION="0.2.0"
ARCHIVE="agent-skills-validator_${VALIDATOR_VERSION}_linux_amd64.tar.gz"
SHA256="11aa2494aa3fed906226d4b364d572f0d2638386157e289cc6bd4da682f7b2cf"
URL="https://github.com/coolapso/agent-skills-validator/releases/download/v${VALIDATOR_VERSION}/${ARCHIVE}"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
cd "$WORKDIR"
curl -sSL --retry 3 --retry-delay 2 -o "$ARCHIVE" "$URL"
echo "${SHA256}  ${ARCHIVE}" | sha256sum -c -
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
