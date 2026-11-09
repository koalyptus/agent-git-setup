#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
cd "$WORKDIR"

OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH="$(uname -m)"
case "$OS" in
  linux) OS_TAG=linux ;;
  darwin) OS_TAG=darwin ;;
  *) echo "Unsupported OS: $OS" >&2; exit 1 ;;
esac
case "$ARCH" in
  x86_64|amd64) ARCH_TAG=amd64 ;;
  aarch64|arm64) ARCH_TAG=arm64 ;;
  *) echo "Unsupported arch: $ARCH" >&2; exit 1 ;;
esac

if command -v sha256sum >/dev/null 2>&1; then
  SHA_CMD=(sha256sum -c)
elif command -v shasum >/dev/null 2>&1; then
  SHA_CMD=(shasum -a 256 -c)
else
  echo "No sha256 tool found" >&2; exit 1
fi

LATEST=$(curl -sSL https://api.github.com/repos/coolapso/agent-skills-validator/releases/latest | python3 -c "import sys,json; print(json.load(sys.stdin)['tag_name'].lstrip('v'))")
ARCHIVE="agent-skills-validator_${LATEST}_${OS_TAG}_${ARCH_TAG}.tar.gz"
URL="https://github.com/coolapso/agent-skills-validator/releases/download/v${LATEST}/${ARCHIVE}"
CHECKSUMS_URL="https://github.com/coolapso/agent-skills-validator/releases/download/v${LATEST}/checksums.txt"

curl -sSL --retry 3 --retry-delay 2 -o "$ARCHIVE" "$URL"
curl -sSL --retry 3 --retry-delay 2 -o checksums.txt "$CHECKSUMS_URL"
grep " ${ARCHIVE}\$" checksums.txt | "${SHA_CMD[@]}"

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

"$BIN" validate "${SKILL_DIRS[@]}"
