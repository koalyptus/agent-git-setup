#!/usr/bin/env bash
#
# make-release-test.sh
#
# Hermetic tests for the `make release` target. Fakes git + gh on PATH,
# runs the target, and asserts the correct push refspec is used.
#
# Requires: bash + make. No real git or gh is invoked — the fakes on PATH
# intercept every call the release target makes.

set -uo pipefail

PASS=0
FAIL=0
ok() {
	PASS=$((PASS + 1))
	echo "  ok   - $1"
}
bad() {
	FAIL=$((FAIL + 1))
	echo "  FAIL - $1"
}
assert_eq() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got '$1' expected '$2')"; fi; }

SANDBOX="$(mktemp -d)"
export HOME="$SANDBOX"
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL="$SANDBOX/.gitconfig"

GIT_CALL_LOG="$SANDBOX/git-calls.log"
GH_CALL_LOG="$SANDBOX/gh-calls.log"
export GIT_CALL_LOG GH_CALL_LOG

mkdir -p "$SANDBOX/bin"

# Fake git: logs all calls, returns appropriate exit codes.
cat >"$SANDBOX/bin/git" <<'GITEOF'
#!/usr/bin/env bash
echo "$@" >> "$GIT_CALL_LOG"
case "$1" in
  rev-parse)
    if [ "$2" = "--abbrev-ref" ]; then echo "main"; exit 0; fi
    if [ "$2" = "-q" ]; then exit 1; fi  # tag doesn't exist
    exit 0;;
  fetch|merge|diff|tag|push) exit 0;;
  *) exit 0;;
esac
GITEOF

# Fake gh: logs all calls, exits 0.
cat >"$SANDBOX/bin/gh" <<'GHEOF'
#!/usr/bin/env bash
echo "$@" >> "$GH_CALL_LOG"
exit 0
GHEOF

chmod +x "$SANDBOX/bin/git" "$SANDBOX/bin/gh"
export PATH="$SANDBOX/bin:$PATH"

# Resolve Makefile to an absolute path before cd into REPO.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAKEFILE="$SCRIPT_DIR/../Makefile"

# Run make from a throwaway directory, never the caller's repo. Every git/gh
# call the release target makes is intercepted by the fakes on PATH, so no real
# repo is needed — but a neutral cwd keeps the target off the caller's tree if
# a fake ever fails to intercept.
REPO="$SANDBOX/repo"
mkdir -p "$REPO"
cd "$REPO" || exit 1

# Run make release with VERSION set.
VERSION="1.2.3"
make -f "$MAKEFILE" release VERSION="$VERSION" >/dev/null 2>&1

# --- Assertions ---

# git push called exactly once.
assert_eq "$(grep -c 'push' "$GIT_CALL_LOG")" "1" "git push called exactly once"

# push uses single refspec: origin "v$(VERSION)".
assert_eq "$(grep 'push' "$GIT_CALL_LOG")" "push origin v${VERSION}" "push uses single refspec origin v${VERSION}"

# No --tags flag.
assert_eq "$(grep -c -- '--tags' "$GIT_CALL_LOG")" "0" "no --tags flag used"

# git tag -a called before git push.
TAG_LINE=$(grep -n 'tag -a' "$GIT_CALL_LOG" | cut -d: -f1)
PUSH_LINE=$(grep -n 'push' "$GIT_CALL_LOG" | cut -d: -f1)
if [ -n "$TAG_LINE" ] && [ -n "$PUSH_LINE" ] && [ "$TAG_LINE" -lt "$PUSH_LINE" ]; then
	ok "git tag -a called before git push"
else
	bad "git tag -a must be called before git push"
fi

# Tag message is the expected release message.
assert_eq "$(grep -c "Release v${VERSION}" "$GIT_CALL_LOG")" "1" "tag message is Release v${VERSION}"

# gh release create called exactly once.
assert_eq "$(grep -c 'release create' "$GH_CALL_LOG")" "1" "gh release create called exactly once"

# gh release create uses --generate-notes.
assert_eq "$(grep -c -- '--generate-notes' "$GH_CALL_LOG")" "1" "gh release create uses --generate-notes"

# No real tag created in the repo.
if git tag | grep -q "^v${VERSION}$"; then
	bad "real tag v${VERSION} should not exist"
else
	ok "no real tag created in repo"
fi

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
