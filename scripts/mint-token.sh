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
# App credentials are NOT seeded from the environment here. Explicit
# --app-id/--pem args take precedence, then persisted credentials files are
# discovered, and only as a last resort does the environment act as a fallback
# (inside resolve_credentials). Pre-seeding from env at the top would let an
# ambient GITHUB_APP_PEM shadow an explicit --pem argument and corrupt the
# documented precedence.
PEM=""
INSTALL_ID=""
CREDENTIALS_FILE="${AGENT_GIT_CREDENTIALS:-}"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/agent-git-setup"
DEFAULT_CREDENTIALS_FILE="$CONFIG_DIR/credentials.env"
SHELL_OUT=0
PRINT_JWT=0

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
	--credentials)
		CREDENTIALS_FILE="$2"
		shift 2
		;;
	--shell)
		SHELL_OUT=1
		shift
		;;
	--print-jwt)
		PRINT_JWT=1
		shift
		;;
	*)
		echo "mint-token.sh: unknown arg $1" >&2
		exit 2
		;;
	esac
done

# Credential-file discovery (one-time, agent-agnostic): if the App ID / PEM
# were not given via env or args, source them from a persisted credentials
# file so the agent never has to pass tokens per session. The file holds only
# GITHUB_APP_ID (public), GITHUB_APP_PEM (path to the secret), and optionally
# AGENT_GIT_BOT_ID (the App's single bot user id, static per App) — never the
# private key bytes or a live token.
#
# Resolution order when creds are not in env/args:
#   1. explicit  --credentials <file> / AGENT_GIT_CREDENTIALS=<file>
#   2. per-App   $CONFIG_DIR/credentials.d/credentials-<APP_ID>.env
#                (first-class: one bot identity per GitHub App / per repo)
#   3. global    $CONFIG_DIR/credentials.env  (single-identity default)
# The agent is given GITHUB_APP_ID in its prompt, so (2) is selected
# automatically — no name->app-id mapping needed (app-id is numeric).
CRED_FILE_USED=""
resolve_credentials() {
	if [ -n "$CREDENTIALS_FILE" ]; then
		CRED_FILE_USED="$CREDENTIALS_FILE"
	elif [ -n "$APP_ID" ] && [ -r "$CONFIG_DIR/credentials.d/credentials-${APP_ID}.env" ]; then
		CRED_FILE_USED="$CONFIG_DIR/credentials.d/credentials-${APP_ID}.env"
	elif [ -r "$DEFAULT_CREDENTIALS_FILE" ]; then
		CRED_FILE_USED="$DEFAULT_CREDENTIALS_FILE"
	fi
}

if [ -z "$APP_ID" ] || [ -z "$PEM" ]; then
	resolve_credentials
	if [ -n "$CRED_FILE_USED" ] && [ -r "$CRED_FILE_USED" ]; then
		# shellcheck disable=SC1090
		. "$CRED_FILE_USED"
	fi
	# Env fallback (last resort) applies whether or not a credentials file was
	# found: file-sourced values win, then the environment fills any gap. This
	# keeps "GITHUB_APP_ID/GITHUB_APP_PEM in env, no args, no file" working,
	# and stays hermetic because the test suite unsets these vars.
	APP_ID="${APP_ID:-${GITHUB_APP_ID:-}}"
	PEM="${PEM:-${GITHUB_APP_PEM:-}}"
	INSTALL_ID="${INSTALL_ID:-${GITHUB_APP_INSTALL_ID:-}}"
	if [ -z "$APP_ID" ] || [ -z "$PEM" ]; then
		echo "mint-token.sh: no App creds in env/args and no credentials file found." >&2
		echo "  Looked for (in order):" >&2
		[ -n "$CREDENTIALS_FILE" ] && echo "    --credentials $CREDENTIALS_FILE" >&2
		[ -n "$APP_ID" ] && echo "    $CONFIG_DIR/credentials.d/credentials-${APP_ID}.env" >&2
		echo "    $DEFAULT_CREDENTIALS_FILE" >&2
		echo "  Create one (chmod 600) with: GITHUB_APP_ID=…  GITHUB_APP_PEM=/path/to.pem" >&2
	fi
fi

: "${APP_ID:?set GITHUB_APP_ID, pass --app-id, or put it in a credentials file (see mint-token.sh discovery order)}"
: "${PEM:?set GITHUB_APP_PEM, pass --pem (path to the app private key .pem), or put it in a credentials file}"

# Build an RS256 JWT from app_id + pem without the `jwt` submodule
# (portable across cryptography versions). Prints the token on stdout.
build_jwt() {
	python3 - "$1" "$2" <<'PY'
import sys, time, json, base64
from cryptography.hazmat.primitives import serialization, hashes
from cryptography.hazmat.primitives.asymmetric import padding

def b64u(b):
    return base64.urlsafe_b64encode(b).rstrip(b"=")

app_id, pem_path = sys.argv[1], sys.argv[2]
now = int(time.time())
header = {"alg": "RS256", "typ": "JWT"}
payload = {"iat": now - 60, "exp": now + 540, "iss": int(app_id)}
seg = b64u(json.dumps(header).encode()) + b"." + b64u(json.dumps(payload).encode())
with open(pem_path, "rb") as f:
    key = serialization.load_pem_private_key(f.read(), password=None)
sig = key.sign(seg, padding.PKCS1v15(), hashes.SHA256())
print((seg + b"." + b64u(sig)).decode())
PY
}

# Offline mode: build and print the JWT only (no network). Used by tests.
if [ "$PRINT_JWT" -eq 1 ]; then
	build_jwt "$APP_ID" "$PEM"
	exit 0
fi

# Mint the installation token (network). Prints the token on stdout.
mint_token() {
	python3 - "$APP_ID" "$PEM" "$INSTALL_ID" <<'PY'
import sys, json, urllib.request, time, base64
from cryptography.hazmat.primitives import serialization, hashes
from cryptography.hazmat.primitives.asymmetric import padding

def b64u(b):
    import base64
    return base64.urlsafe_b64encode(b).rstrip(b"=")

app_id, pem_path, install_id = sys.argv[1], sys.argv[2], sys.argv[3]
now = int(time.time())
header = {"alg": "RS256", "typ": "JWT"}
payload = {"iat": now - 60, "exp": now + 540, "iss": int(app_id)}
seg = b64u(json.dumps(header).encode()) + b"." + b64u(json.dumps(payload).encode())
with open(pem_path, "rb") as f:
    key = serialization.load_pem_private_key(f.read(), password=None)
sig = key.sign(seg, padding.PKCS1v15(), hashes.SHA256())
bearer = (seg + b"." + b64u(sig)).decode()

def api(path, method="GET", data=None):
    req = urllib.request.Request(
        "https://api.github.com" + path,
        data=data, method=method,
        headers={"Authorization": "Bearer " + bearer,
                 "Accept": "application/vnd.github+json"})
    with urllib.request.urlopen(req, timeout=30) as r:
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
}

TOKEN="$(mint_token)"

if [ "$SHELL_OUT" -eq 1 ]; then
	echo "export GH_TOKEN=$TOKEN"
	# Emit the App's bot id (if known) so the agent can persist it into the
	# credentials file / env. AGENT_GIT_BOT_ID is static per App; when present,
	# agent-git-setup.sh uses it as the commit-email prefix so commits are
	# attributed to the bot account, not the account owner. Git-only flows never run
	# this script and are unaffected.
	if [ -n "${AGENT_GIT_BOT_ID:-}" ]; then
		echo "export AGENT_GIT_BOT_ID=$AGENT_GIT_BOT_ID"
	fi
else
	printf '%s\n' "$TOKEN"
fi
