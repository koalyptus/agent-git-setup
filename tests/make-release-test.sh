#!/usr/bin/env bash
#
# make-release-test.sh
#
# Hermetic tests for the `make release` target. Fakes git + gh on PATH,
# runs the target, and asserts the correct push refspec is used, including the
# push-failure recovery path (#29).
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

# The fake git tracks whether the tag exists in a state file, so it models the
# real failure mode: the annotated tag survives an aborted run.
GIT_STATE="$SANDBOX/tag-state"
export GIT_STATE
echo 0 >"$GIT_STATE"

mkdir -p "$SANDBOX/bin"

# Fake git: logs all calls and tracks tag existence across calls.
cat >"$SANDBOX/bin/git" <<'GITEOF'
#!/usr/bin/env bash
echo "$@" >> "$GIT_CALL_LOG"
state="${GIT_STATE:-/dev/null}"
case "$1" in
  rev-parse)
    if [ "$2" = "--abbrev-ref" ]; then echo "main"; exit 0; fi
    if [ "$2" = "-q" ]; then
      [ -f "$state" ] && [ "$(cat "$state")" = "1" ] && exit 0
      exit 1
    fi
    exit 0;;
  tag)
    case "$2" in
      -a) echo 1 >"$state"; exit 0;;
      -d) echo 0 >"$state"; exit 0;;
      *) exit 0;;
    esac;;
  push)
    # Simulate a failed push (no credentials, no write access, stale ref).
    [ "${FAIL_PUSH:-0}" = "1" ] && exit 1
    exit 0;;
  fetch|merge|diff) exit 0;;
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

VERSION="1.2.3"

# --- Happy path: tag, push, GitHub Release. ---

echo 0 >"$GIT_STATE"
make -f "$MAKEFILE" release VERSION="$VERSION" >/dev/null 2>&1

assert_eq "$(grep -c 'push' "$GIT_CALL_LOG")" "1" "git push called exactly once"
assert_eq "$(grep 'push' "$GIT_CALL_LOG")" "push origin v${VERSION}" "push uses single refspec origin v${VERSION}"
assert_eq "$(grep -c -- '--tags' "$GIT_CALL_LOG")" "0" "no --tags flag used"

TAG_LINE=$(grep -n 'tag -a' "$GIT_CALL_LOG" | cut -d: -f1)
PUSH_LINE=$(grep -n 'push' "$GIT_CALL_LOG" | cut -d: -f1)
if [ -n "$TAG_LINE" ] && [ -n "$PUSH_LINE" ] && [ "$TAG_LINE" -lt "$PUSH_LINE" ]; then
	ok "git tag -a called before git push"
else
	bad "git tag -a must be called before git push"
fi

assert_eq "$(grep -c "Release v${VERSION}" "$GIT_CALL_LOG")" "1" "tag message is Release v${VERSION}"
assert_eq "$(grep -c 'release create' "$GH_CALL_LOG")" "1" "gh release create called exactly once"
assert_eq "$(grep -c -- '--generate-notes' "$GH_CALL_LOG")" "1" "gh release create uses --generate-notes"
assert_eq "$(cat "$GIT_STATE")" "1" "tag still exists after a successful release"

# --- Push failure: the tag lands locally but the push fails (#29). ---

fail_dir="$SANDBOX/fail"
mkdir -p "$fail_dir"
echo 0 >"$GIT_STATE" # fresh clone: no local tag
: >"$GIT_CALL_LOG"   # isolate this attempt in the log
: >"$GH_CALL_LOG"
FAIL_PUSH=1 make -f "$MAKEFILE" release VERSION="$VERSION" >"$fail_dir/out" 2>&1
fail_exit=$?

if [ "$fail_exit" -eq 0 ]; then
	bad "push failure must not exit 0"
else
	ok "push failure exits non-zero"
fi

assert_eq "$(grep -c '^tag -d' "$GIT_CALL_LOG")" "1" "stale local tag deleted on push failure"
assert_eq "$(grep '^tag -d' "$GIT_CALL_LOG")" "tag -d v${VERSION}" "tag deleted with tag -d v${VERSION}"

TAG_LINE=$(grep -n '^tag -a' "$GIT_CALL_LOG" | cut -d: -f1)
DELETE_LINE=$(grep -n '^tag -d' "$GIT_CALL_LOG" | cut -d: -f1)
if [ -n "$TAG_LINE" ] && [ -n "$DELETE_LINE" ] && [ "$TAG_LINE" -lt "$DELETE_LINE" ]; then
	ok "tag deleted after it was created"
else
	bad "tag must be deleted after creation"
fi

# A retry must be able to recreate the tag: the stale one is gone.
assert_eq "$(cat "$GIT_STATE")" "0" "stale tag is gone so a retry can proceed"

if grep -q 'release create' "$GH_CALL_LOG"; then
	bad "gh release create must not run when the push fails"
else
	ok "gh release create not attempted on push failure"
fi

# The failure output must tell the operator the tag was cleaned up and how to
# retry, so a failed push is recoverable without knowing the target's internals.
if grep -q 'deleted the local tag' "$fail_dir/out"; then
	ok "push failure reports the local tag was deleted"
else
	bad "push failure must report the local tag was deleted"
fi

if grep -q 'retry with' "$fail_dir/out"; then
	ok "push failure gives the retry command"
else
	bad "push failure must give the retry command"
fi

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
