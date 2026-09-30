#!/usr/bin/env bash
# Hermetic coverage for the agent-github-access skill workflow.
set -euo pipefail
umask 077

unset GITHUB_APP_ID GITHUB_APP_PEM GITHUB_APP_NAME GITHUB_APP_INSTALL_ID GH_TOKEN GH_ENTERPRISE_TOKEN GITHUB_TOKEN GH_HOST GH_REPO AGENT_GIT_CREDENTIALS AGENT_GIT_TOKEN_ACTOR AGENT_GIT_TOKEN_SHA256 AGENT_GIT_TOKEN_ATTESTATION AGENT_GIT_TOKEN_APP_ID AGENT_GIT_TOKEN_APP_PEM_PATH GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE PYTHONPATH

TEST_HOME="$(mktemp -d -t github-access.XXXXXX)"
export HOME="$TEST_HOME/home"
export XDG_CONFIG_HOME="$TEST_HOME/xdg"
export GIT_CONFIG_GLOBAL="$TEST_HOME/gitconfig"
export GIT_CONFIG_NOSYSTEM=1
mkdir -p "$HOME" "$XDG_CONFIG_HOME/agent-git-setup" "$TEST_HOME/bin"
export PATH="$TEST_HOME/bin:$PATH"

cleanup() {
	rm -rf "$TEST_HOME"
}
trap cleanup EXIT

if ! command -v python3 >/dev/null 2>&1 || ! python3 -c 'import cryptography' >/dev/null 2>&1; then
	echo "agent-github-access-test.sh requires Python 3 and cryptography" >&2
	exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MINT_TOKEN_SCRIPT="$SCRIPT_DIR/scripts/mint-token.sh"
SKILL_DOC="$SCRIPT_DIR/skills/agent-github-access/SKILL.md"
GIT_SKILL_DOC="$SCRIPT_DIR/skills/agent-git-setup/SKILL.md"

echo "new skill documents the tested mint-and-verify workflow"
# These are literal code samples in the skill document, not shell expansions.
# shellcheck disable=SC2016
if grep -Fq 'source <("$MINT_TOKEN_BASH" --shell)' "$SKILL_DOC" &&
	grep -Fq '& $MINT_TOKEN_POWERSHELL' "$SKILL_DOC" &&
	grep -Fq 'gh repo view --json nameWithOwner --jq .nameWithOwner' "$SKILL_DOC"; then
	echo "  ok   - skill documents platform-specific minters and current-repo verification"
else
	echo "  FAIL - skill workflow commands do not match the tested flow"
	exit 1
fi

echo "bot-identity failures require explicit human approval"
if grep -Fq 'May I create commits as this human identity' "$GIT_SKILL_DOC" &&
	grep -Fq 'If the human declines' "$GIT_SKILL_DOC" &&
	grep -Fq 'May I perform' "$SKILL_DOC" &&
	grep -Fq 'Only after explicit approval' "$SKILL_DOC" &&
	grep -Fq 'show the public App IDs from their filenames' "$SKILL_DOC" &&
	grep -Fq 'ask the human which App to use' "$SKILL_DOC"; then
	echo "  ok   - skills require consent and explicit App choice when credentials are ambiguous"
else
	echo "  FAIL - skills must require consent and explicit App choice when credentials are ambiguous"
	exit 1
fi

echo "isolated configured credentials and synthetic App key"
PEM_PATH="$TEST_HOME/app-private-key.pem"
python3 - "$PEM_PATH" <<'PY'
import sys
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa

key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
with open(sys.argv[1], "wb") as key_file:
    key_file.write(key.private_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PrivateFormat.TraditionalOpenSSL,
        encryption_algorithm=serialization.NoEncryption(),
    ))
PY
CREDENTIALS_FILE="$XDG_CONFIG_HOME/agent-git-setup/credentials.env"
printf 'GITHUB_APP_ID=1234567\nGITHUB_APP_PEM=%s\n' "$PEM_PATH" >"$CREDENTIALS_FILE"
cp "$CREDENTIALS_FILE" "$TEST_HOME/credentials.before"

FAKE_API_DIR="$TEST_HOME/fake-api"
mkdir -p "$FAKE_API_DIR"
cat >"$FAKE_API_DIR/sitecustomize.py" <<'PY'
import json
import urllib.request


class FakeResponse:
    def __init__(self, payload):
        self.body = json.dumps(payload).encode()

    def read(self, *args):
        return self.body

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False


def fake_urlopen(request, *args, **kwargs):
    if not request.full_url.startswith("https://api.github.com/"):
        raise RuntimeError("unexpected network request: " + request.full_url)
    if request.full_url.endswith("/app"):
        return FakeResponse({"id": 1234567, "slug": "fixture-app"})
    if request.full_url.endswith("/app/installations"):
        return FakeResponse([{"id": 42}])
    if request.full_url.endswith("/app/installations/42/access_tokens"):
        return FakeResponse({"token": "ghs.synthetic-installation-token"})
    raise RuntimeError("unexpected GitHub API request: " + request.full_url)


urllib.request.urlopen = fake_urlopen
PY

cat >"$TEST_HOME/bin/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

if [ "$*" != "repo view --json nameWithOwner --jq .nameWithOwner" ]; then
	echo "unexpected gh invocation: $*" >&2
	exit 2
fi
if [ "${GH_TOKEN:-}" != "ghs.synthetic-installation-token" ]; then
	echo "GH_TOKEN missing or unexpected" >&2
	exit 3
fi
if [ "${AGENT_GIT_TOKEN_ACTOR:-}" != "fixture-app[bot]" ] || [ "${AGENT_GIT_TOKEN_APP_ID:-}" != "1234567" ]; then
	echo "App token attestation metadata missing" >&2
	exit 4
fi
if [ "$(git remote get-url origin)" != "https://github.com/acme/widget.git" ]; then
	echo "unexpected current repository origin" >&2
	exit 5
fi
printf 'acme/widget\n'
SH
chmod +x "$TEST_HOME/bin/gh"

case "$(uname -s)" in
MINGW* | MSYS* | CYGWIN*)
	WINDOWS_FAKE_API_DIR="$(cygpath -w "$FAKE_API_DIR")"
	export PYTHONPATH="$WINDOWS_FAKE_API_DIR"
	;;
*) export PYTHONPATH="$FAKE_API_DIR" ;;
esac

REPO_DIR="$TEST_HOME/repo"
mkdir -p "$REPO_DIR"
git -C "$REPO_DIR" init -q
git -C "$REPO_DIR" remote add origin https://github.com/acme/widget.git
cd "$REPO_DIR"

echo "mint and verify with local fixtures only"
# The minter emits trusted shell exports; ShellCheck cannot resolve its path.
# shellcheck disable=SC1090
source <("$MINT_TOKEN_SCRIPT" --shell)
if [ "${AGENT_GIT_TOKEN_ACTOR:-}" = "fixture-app[bot]" ] && [ -n "${AGENT_GIT_TOKEN_ATTESTATION:-}" ]; then
	echo "  ok   - existing minter exports the App actor and signed attestation"
else
	echo "  FAIL - minter did not export complete App token metadata"
	exit 1
fi

if GH_RESULT="$(gh repo view --json nameWithOwner --jq .nameWithOwner)" && [ "$GH_RESULT" = "acme/widget" ]; then
	echo "  ok   - gh verifies access to the current repository with the minted token"
else
	echo "  FAIL - gh did not verify current-repository access"
	exit 1
fi

if cmp -s "$CREDENTIALS_FILE" "$TEST_HOME/credentials.before" && ! grep -R -Fq 'ghs.synthetic-installation-token' "$XDG_CONFIG_HOME" "$HOME"; then
	echo "  ok   - credentials stay unchanged and the token is not persisted"
else
	echo "  FAIL - test workflow modified credentials or persisted its token"
	exit 1
fi

echo "PASS=4 FAIL=0"
