#!/usr/bin/env bash
#
# mint-token.sh - mint a GitHub App installation token (neutral, self-contained).
#
# This is the token SOURCE for the happy path. agent-git-setup.sh only consumes
# GH_TOKEN; this script produces it from a GitHub App (App ID + PEM). It is the
# in-repo replacement for any backend-specific minter (e.g. hermes_token.py).
#
# Requires: python3 with the 'cryptography' package (standard on most systems).
#
set -euo pipefail

APP_ID="${GITHUB_APP_ID:-}"
PEM="${GITHUB_APP_PEM:-}"
INSTALL_ID="${GITHUB_APP_INSTALL_ID:-}"
SHELL_OUT=0

while [ $# -gt 0 ]; do
	case "$1" in
	--app-id)
		APP_ID="$2"
		shift 2
		;;
	--pem)
		PEM="$2"
		shift 2
		;;
	--installation-id)
		INSTALL_ID="$2"
		shift 2
		;;
	--shell)
		SHELL_OUT=1
		shift
		;;
	*)
		echo "mint-token.sh: unknown arg $1" >&2
		exit 2
		;;
	esac
done

: "${APP_ID:?set GITHUB_APP_ID or pass --app-id}"
: "${PEM:?set GITHUB_APP_PEM or pass --pem (path to the app private key .pem)}"

TOKEN="$(
	python3 - "$APP_ID" "$PEM" "$INSTALL_ID" <<'PY'
import sys, time, json, urllib.request
try:
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric import jwt
except ImportError:
    sys.stderr.write("mint-token.sh: python 'cryptography' package is required\n")
    sys.exit(1)

app_id, pem_path, install_id = sys.argv[1], sys.argv[2], sys.argv[3]
now = int(time.time())
payload = {"iat": now - 60, "exp": now + 540, "iss": int(app_id)}
with open(pem_path, "rb") as f:
    key = serialization.load_pem_private_key(f.read(), password=None)
bearer = jwt.encode(payload, key, algorithm="RS256")

def api(path, method="GET", data=None):
    req = urllib.request.Request(
        "https://api.github.com" + path,
        data=data, method=method,
        headers={"Authorization": "Bearer " + bearer,
                 "Accept": "application/vnd.github+json"})
    with urllib.request.urlopen(req) as r:
        return json.load(r)

installs = api("/app/installations")
if install_id:
    inst = next((i for i in installs if str(i["id"]) == str(install_id)), None)
else:
    inst = installs[0] if installs else None
if inst is None:
    sys.stderr.write("mint-token.sh: no installation found for this app\n")
    sys.exit(1)

tok = api("/app/installations/%d/access_tokens" % inst["id"], method="POST", data=b"")
print(tok["token"])
PY
)"

if [ "$SHELL_OUT" -eq 1 ]; then
	echo "export GH_TOKEN=$TOKEN"
else
	printf '%s\n' "$TOKEN"
fi
