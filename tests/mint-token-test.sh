#!/usr/bin/env bash
#
# mint-token-test.sh - hermetic tests for mint-token.sh.
#
# Every test runs OFFLINE (no network, no real GitHub App) using ephemeral
# RSA keys generated in a temp dir. The only network call (real end-to-end
# mint) is GATED behind GITHUB_APP_PEM and skipped otherwise, so CI stays
# fully hermetic. Covers all credential resolution paths, precedence rules,
# error handling, and output formats.
#
# HERMETIC SEAL: the tests mints use an ephemeral key with app-id 4646191 and
# verify against it. If ambient GITHUB_APP_ID / GITHUB_APP_PEM / GH_TOKEN are
# present in the environment (e.g. a developer shell that just minted a real
# token), mint-token.sh's discovery paths would pick them up and mint a JWT
# with the wrong iss / key, failing the hardcoded verification. Unset them so
# the suite is deterministic regardless of the calling environment.
#
set -uo pipefail

unset GITHUB_APP_ID GITHUB_APP_PEM GITHUB_APP_NAME GH_TOKEN

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../scripts/mint-token.sh"

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

# --- fixtures ---------------------------------------------------------------
make_pem() {
	local p
	p="$(mktemp -t mintpem.XXXXXX.pem)"
	openssl genrsa -out "$p" 2048 2>/dev/null
	echo "$p"
}
PEM_FOR_TEST="$(make_pem)"
PUB_FOR_TEST="$(mktemp -t mintpub.XXXXXX.pem)"
openssl rsa -in "$PEM_FOR_TEST" -pubout -out "$PUB_FOR_TEST" 2>/dev/null

# verify a JWT (iss + RS256 signature) against a public key; prints nothing on success
verify_jwt() {
	python3 - "$1" "$2" <<'PY'
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
}

cleanup() { rm -f "$PEM_FOR_TEST" "$PUB_FOR_TEST" "${PUB2:-}" "${CRED_FILE:-}"; }
trap cleanup EXIT

# --- 1. Missing --app-id (arg path) ----------------------------------------
echo "missing --app-id"
if "$SCRIPT" --pem "$PEM_FOR_TEST" >/dev/null 2>&1; then
	bad "should fail without --app-id"
else
	ok "fails without --app-id"
fi

# --- 2. Missing --pem (arg path) -------------------------------------------
echo "missing --pem"
if "$SCRIPT" --app-id 123 >/dev/null 2>&1; then
	bad "should fail without --pem"
else
	ok "fails without --pem"
fi

# --- 3. Unknown arg --------------------------------------------------------
echo "unknown arg"
if "$SCRIPT" --bogus >/dev/null 2>&1; then
	bad "should fail on unknown arg"
else
	ok "fails on unknown arg"
fi

# --- 4. JWT generation offline (args) + full verification ------------------
echo "jwt generation offline (args)"
JWT="$("$SCRIPT" --app-id 4646191 --pem "$PEM_FOR_TEST" --print-jwt 2>/dev/null)"
if [ -z "$JWT" ]; then
	bad "no JWT produced"
elif verify_jwt "$PUB_FOR_TEST" "$JWT"; then
	ok "JWT valid RS256, iss=4646191, signature verifies"
else
	bad "JWT invalid (exit $?)"
fi

# --- 5. --shell output format (args) ---------------------------------------
echo "--shell output format (args)"
SHELL_LINE="$("$SCRIPT" --app-id 4646191 --pem "$PEM_FOR_TEST" --print-jwt --shell 2>/dev/null)"
case "$SHELL_LINE" in
*.*.*) ok "--shell still emits the JWT" ;;
*) bad "--shell output unexpected: $SHELL_LINE" ;;
esac

# --- 6. Env-var resolution (no args) ---------------------------------------
echo "env-var resolution (no args)"
ENV_JWT="$(GITHUB_APP_ID=4646191 GITHUB_APP_PEM="$PEM_FOR_TEST" "$SCRIPT" --print-jwt 2>/dev/null)"
if [ -z "$ENV_JWT" ]; then
	bad "no JWT from env vars"
elif verify_jwt "$PUB_FOR_TEST" "$ENV_JWT"; then
	ok "mints from GITHUB_APP_ID/GITHUB_APP_PEM env vars"
else
	bad "env-var JWT invalid (exit $?)"
fi

# --- 7. Credential-file discovery (no env, no args) -----------------------
echo "credential-file discovery (no env/args)"
CRED_FILE="$(mktemp -t agcreds.XXXXXX.env)"
printf 'GITHUB_APP_ID=4646191\nGITHUB_APP_PEM=%s\n' "$PEM_FOR_TEST" >"$CRED_FILE"
DISC_JWT="$("$SCRIPT" --print-jwt --credentials "$CRED_FILE" 2>/dev/null)"
if [ -z "$DISC_JWT" ]; then
	bad "no JWT from credential-file discovery"
elif verify_jwt "$PUB_FOR_TEST" "$DISC_JWT"; then
	ok "mints from credential file with no env/args"
else
	bad "credential-file JWT invalid (exit $?)"
fi

# --- 7b. Per-App credentials.d discovery (no env, no args, APP_ID via --app-id)
echo "per-App credentials.d discovery (APP_ID given, no creds file in env)"
# Isolation: use a temp XDG_CONFIG_HOME so we never touch the real ~/.config.
CRED_XDG="$(mktemp -d -t agxdg.XXXXXX)"
mkdir -p "$CRED_XDG/agent-git-setup/credentials.d"
printf 'GITHUB_APP_ID=4646191\nGITHUB_APP_PEM=%s\n' "$PEM_FOR_TEST" >"$CRED_XDG/agent-git-setup/credentials.d/credentials-4646191.env"
PERAPP_JWT="$(XDG_CONFIG_HOME="$CRED_XDG" "$SCRIPT" --app-id 4646191 --print-jwt 2>/dev/null)"
rm -rf "$CRED_XDG"
if [ -z "$PERAPP_JWT" ]; then
	bad "no JWT from per-App credentials.d discovery"
elif verify_jwt "$PUB_FOR_TEST" "$PERAPP_JWT"; then
	ok "auto-discovers credentials.d/credentials-<APP_ID>.env"
else
	bad "per-App credentials.d JWT invalid (exit $?)"
fi

# --- 7c. Precedence: per-App credentials.d wins over global credentials.env
echo "precedence: per-App credentials.d overrides global credentials.env"
CRED_XDG2="$(mktemp -d -t agxdg2.XXXXXX)"
mkdir -p "$CRED_XDG2/agent-git-setup/credentials.d"
# global says app 9999999; per-App for 4646191 is the one that should win
printf 'GITHUB_APP_ID=9999999\nGITHUB_APP_PEM=%s\n' "$PEM_FOR_TEST" >"$CRED_XDG2/agent-git-setup/credentials.env"
printf 'GITHUB_APP_ID=4646191\nGITHUB_APP_PEM=%s\n' "$PEM_FOR_TEST" >"$CRED_XDG2/agent-git-setup/credentials.d/credentials-4646191.env"
PRE_PERAPP_JWT="$(XDG_CONFIG_HOME="$CRED_XDG2" "$SCRIPT" --app-id 4646191 --print-jwt 2>/dev/null)"
rm -rf "$CRED_XDG2"
if [ -z "$PRE_PERAPP_JWT" ]; then
	bad "no JWT when both per-App and global present"
elif verify_jwt "$PUB_FOR_TEST" "$PRE_PERAPP_JWT"; then
	# assert iss is the APP_ID passed (4646191) -> per-App file was used, not global
	if [ "$(python3 -c "import sys,base64,json;p=sys.argv[1].split('.')[1];print(json.loads(base64.urlsafe_b64decode(p+'='*(-len(p)%4)))['iss'])" "$PRE_PERAPP_JWT")" = "4646191" ]; then
		ok "per-App credentials.d takes precedence over global credentials.env"
	else
		bad "global credentials.env overrode per-App (iss mismatch)"
	fi
else
	bad "per-App-precedence JWT invalid (exit $?)"
fi

# --- 7d. Precedence: explicit --credentials wins over per-App discovery ----
echo "precedence: explicit --credentials overrides per-App discovery"
CRED_XDG3="$(mktemp -d -t agxdg3.XXXXXX)"
mkdir -p "$CRED_XDG3/agent-git-setup/credentials.d"
printf 'GITHUB_APP_ID=4646191\nGITHUB_APP_PEM=%s\n' "$PEM_FOR_TEST" >"$CRED_XDG3/agent-git-setup/credentials.d/credentials-4646191.env"
EXPLICIT_CRED="$(mktemp -t agexpl.XXXXXX.env)"
printf 'GITHUB_APP_ID=4646191\nGITHUB_APP_PEM=%s\n' "$PEM_FOR_TEST" >"$EXPLICIT_CRED"
EXPL_JWT="$(XDG_CONFIG_HOME="$CRED_XDG3" "$SCRIPT" --app-id 4646191 --print-jwt --credentials "$EXPLICIT_CRED" 2>/dev/null)"
rm -rf "$CRED_XDG3" "$EXPLICIT_CRED"
if [ -z "$EXPL_JWT" ]; then
	bad "no JWT with explicit --credentials + per-App present"
elif verify_jwt "$PUB_FOR_TEST" "$EXPL_JWT"; then
	ok "explicit --credentials wins over per-App discovery"
else
	bad "explicit-credentials JWT invalid (exit $?)"
fi

# --- 8. Precedence: args win over credential file --------------------------
echo "precedence: args override credential file"
# creds file points at the test PEM; args also point at the same PEM, but we
# prove args are read by giving a DIFFERENT app id in the file and asserting
# the arg's iss (4646191) wins.
CRED_FILE2="$(mktemp -t agcreds2.XXXXXX.env)"
printf 'GITHUB_APP_ID=9999999\nGITHUB_APP_PEM=%s\n' "$PEM_FOR_TEST" >"$CRED_FILE2"
PRE_JWT="$("$SCRIPT" --app-id 4646191 --pem "$PEM_FOR_TEST" --print-jwt --credentials "$CRED_FILE2" 2>/dev/null)"
rm -f "$CRED_FILE2"
if [ -z "$PRE_JWT" ]; then
	bad "no JWT when args + creds both present"
elif verify_jwt "$PUB_FOR_TEST" "$PRE_JWT"; then
	# confirm iss is the ARG value (4646191), not the file's 9999999
	if [ "$(python3 -c "import sys,base64,json;p=sys.argv[1].split('.')[1];print(json.loads(base64.urlsafe_b64decode(p+'='*(-len(p)%4)))['iss'])" "$PRE_JWT")" = "4646191" ]; then
		ok "args take precedence over credential file"
	else
		bad "credential file overrode args (iss mismatch)"
	fi
else
	bad "precedence JWT invalid (exit $?)"
fi

# --- 9. Precedence: env wins over credential file --------------------------
echo "precedence: env overrides credential file"
CRED_FILE3="$(mktemp -t agcreds3.XXXXXX.env)"
printf 'GITHUB_APP_ID=9999999\nGITHUB_APP_PEM=%s\n' "$PEM_FOR_TEST" >"$CRED_FILE3"
ENV_PRE_JWT="$(GITHUB_APP_ID=4646191 GITHUB_APP_PEM="$PEM_FOR_TEST" "$SCRIPT" --print-jwt --credentials "$CRED_FILE3" 2>/dev/null)"
rm -f "$CRED_FILE3"
if [ -z "$ENV_PRE_JWT" ]; then
	bad "no JWT when env + creds both present"
elif verify_jwt "$PUB_FOR_TEST" "$ENV_PRE_JWT"; then
	if [ "$(python3 -c "import sys,base64,json;p=sys.argv[1].split('.')[1];print(json.loads(base64.urlsafe_b64decode(p+'='*(-len(p)%4)))['iss'])" "$ENV_PRE_JWT")" = "4646191" ]; then
		ok "env takes precedence over credential file"
	else
		bad "credential file overrode env (iss mismatch)"
	fi
else
	bad "env-precedence JWT invalid (exit $?)"
fi

# --- 10. Missing credential file -> clear error ----------------------------
echo "missing credential file -> error"
ERR_MSG="$("$SCRIPT" --print-jwt --credentials /nonexistent/path/creds.env 2>&1 >/dev/null)"
RC=$?
if [ "$RC" -ne 0 ] && echo "$ERR_MSG" | grep -q 'GITHUB_APP_ID'; then
	ok "errors clearly when credential file missing"
else
	bad "should error on missing credential file (rc=$RC)"
fi

# --- 11. Unreadable credential file -> error ------------------------------
echo "unreadable credential file -> error"
BAD_CRED="$(mktemp -t agbad.XXXXXX.env)"
printf 'GITHUB_APP_ID=4646191\nGITHUB_APP_PEM=%s\n' "$PEM_FOR_TEST" >"$BAD_CRED"
chmod 000 "$BAD_CRED"
RC2="$(
	"$SCRIPT" --print-jwt --credentials "$BAD_CRED" >/dev/null 2>&1
	echo $?
)"
chmod 600 "$BAD_CRED"
rm -f "$BAD_CRED"
if [ "$RC2" -ne 0 ]; then
	ok "errors on unreadable credential file"
else
	bad "should error on unreadable credential file"
fi

# --- 12. Bad PEM path -> error ---------------------------------------------
echo "bad PEM path -> error"
CRED_BADPEM="$(mktemp -t agbadpem.XXXXXX.env)"
printf 'GITHUB_APP_ID=4646191\nGITHUB_APP_PEM=/nonexistent/key.pem\n' >"$CRED_BADPEM"
if "$SCRIPT" --print-jwt --credentials "$CRED_BADPEM" >/dev/null 2>&1; then
	bad "should fail with bad PEM path"
else
	ok "fails with bad PEM path"
fi
rm -f "$CRED_BADPEM"

# --- 13. PEM passed positionally weird / file discovery reads only expected keys
echo "credential file with extra/surrounding content is tolerated"
CRED_MESSY="$(mktemp -t agmessy.XXXXXX.env)"
printf '# comment line\nGITHUB_APP_ID=4646191\nexport GITHUB_APP_PEM=%s\nSOME_OTHER_VAR=ignored\n' "$PEM_FOR_TEST" >"$CRED_MESSY"
MESSY_JWT="$("$SCRIPT" --print-jwt --credentials "$CRED_MESSY" 2>/dev/null)"
rm -f "$CRED_MESSY"
if [ -z "$MESSY_JWT" ]; then
	bad "no JWT from messy credential file"
elif verify_jwt "$PUB_FOR_TEST" "$MESSY_JWT"; then
	ok "tolerates comments/extra vars in credential file"
else
	bad "messy credential-file JWT invalid (exit $?)"
fi

# --- 14. Real end-to-end mint (gated, network) ----------------------------
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
