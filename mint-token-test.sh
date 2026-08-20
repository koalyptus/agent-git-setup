#!/usr/bin/env bash
#
# mint-token-test.sh - hermetic tests for mint-token.sh.
#
# Covers argument/error handling and JWT generation OFFLINE (no network, no
# real GitHub App). A real end-to-end mint is exercised only if GITHUB_APP_PEM
# is set (skipped otherwise, so CI stays hermetic).
#
set -uo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/mint-token.sh"

PASS=0
FAIL=0
ok() {
	echo "  ok   - $1"
	PASS=$((PASS + 1))
}
bad() {
	echo "  FAIL - $1"
	FAIL=$((FAIL + 1))
}

make_pem() {
	local p
	p="$(mktemp -t mintpem.XXXXXX.pem)"
	openssl genrsa -out "$p" 2048 2>/dev/null
	echo "$p"
}
PEM_FOR_TEST="$(make_pem)"
cleanup() { rm -f "$PEM_FOR_TEST" "${PUB:-}"; }
trap cleanup EXIT

# 1. Missing --app-id
echo "missing --app-id"
if "$SCRIPT" --pem "$PEM_FOR_TEST" >/dev/null 2>&1; then
	bad "should fail without --app-id"
else
	ok "fails without --app-id"
fi

# 2. Missing --pem
echo "missing --pem"
if "$SCRIPT" --app-id 123 >/dev/null 2>&1; then
	bad "should fail without --pem"
else
	ok "fails without --pem"
fi

# 3. Unknown arg
echo "unknown arg"
if "$SCRIPT" --bogus >/dev/null 2>&1; then
	bad "should fail on unknown arg"
else
	ok "fails on unknown arg"
fi

# 4. JWT generation offline (ephemeral key) + full verification
echo "jwt generation offline"
JWT="$("$SCRIPT" --app-id 4646191 --pem "$PEM_FOR_TEST" --print-jwt 2>/dev/null)"
PUB="$(mktemp -t mintpub.XXXXXX.pem)"
openssl rsa -in "$PEM_FOR_TEST" -pubout -out "$PUB" 2>/dev/null
if [ -z "$JWT" ]; then
	bad "no JWT produced"
else
	if python3 - "$PUB" "$JWT" <<'PY'; then
import sys, base64, json
from cryptography.hazmat.primitives import serialization, hashes
from cryptography.hazmat.primitives.asymmetric import padding
pub_path, jwt = sys.argv[1], sys.argv[2]
parts = jwt.split(".")
if len(parts) != 3:
    sys.exit(2)
header = json.loads(base64.urlsafe_b64decode(parts[0] + "=" * (-len(parts[0]) % 4)))
payload = json.loads(base64.urlsafe_b64decode(parts[1] + "=" * (-len(parts[1]) % 4)))
sig = base64.urlsafe_b64decode(parts[2] + "=" * (-len(parts[2]) % 4))
if header.get("alg") != "RS256":
    sys.exit(3)
if payload.get("iss") != 4646191:
    sys.exit(4)
with open(pub_path, "rb") as f:
    pub = serialization.load_pem_public_key(f.read())
try:
    pub.verify(sig, (parts[0] + "." + parts[1]).encode(), padding.PKCS1v15(), hashes.SHA256())
except Exception:
    sys.exit(5)
sys.exit(0)
PY
		ok "JWT valid RS256, iss=4646191, signature verifies"
	else
		bad "JWT invalid (exit $?)"
	fi
	rm -f "$PUB"
fi

# 5. --shell output format (token path emits a JWT)
echo "--shell output"
SHELL_LINE="$("$SCRIPT" --app-id 4646191 --pem "$PEM_FOR_TEST" --print-jwt --shell 2>/dev/null)"
case "$SHELL_LINE" in
*.*.*) ok "--shell still emits the JWT" ;;
*) bad "--shell output unexpected: $SHELL_LINE" ;;
esac

# 6. Real end-to-end mint (gated)
echo "real mint (gated)"
if [ -n "${GITHUB_APP_PEM:-}" ]; then
	TOK="$("$SCRIPT" --shell 2>/dev/null)"
	if echo "$TOK" | grep -q '^export GH_TOKEN='; then
		ok "real mint emits export GH_TOKEN"
	else
		bad "real mint output wrong"
	fi
else
	ok "skipped (no GITHUB_APP_PEM set)"
fi

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
