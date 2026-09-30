#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
	printf 'Usage: agent-git-restore-main-identity.sh --confirm [<repo-dir>]\n'
	exit 0
fi
exec bash "$SCRIPT_DIR/lib/main-identity-core.sh" restore "$@"