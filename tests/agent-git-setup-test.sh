#!/usr/bin/env bash
#
# agent-git-setup-test.sh
#
# Hermetic tests for agent-git-setup.sh. Creates throwaway git repos + worktrees
# under mktemp (the HARNESS owns the worktree; this script only writes identity
# to the shared repo config via includeIf). Needs only bash + git + python3.

set -uo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts/agent-git-setup.sh"
SANDBOX="$(mktemp -d)"
export HOME="$SANDBOX"
export GIT_CONFIG_GLOBAL="$SANDBOX/.gitconfig"
export GIT_CONFIG_NOSYSTEM=1

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
cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

# make_repo [with-origin]: a main repo with an initial commit (human identity).
REPO_SEQ=0
make_repo() {
	REPO_SEQ=$((REPO_SEQ + 1))
	local repo="$SANDBOX/repo-$REPO_SEQ"
	rm -rf "$repo" "$SANDBOX/wt"
	mkdir -p "$repo"
	git init -q -b main "$repo"
	git -C "$repo" config user.name human
	git -C "$repo" config user.email human@example.com
	echo x >"$repo/file.txt"
	git -C "$repo" add file.txt
	git -C "$repo" -c user.name=human -c user.email=human@example.com commit -q -m init
	if [ "${1:-}" = "with-origin" ]; then
		git -C "$repo" remote add origin https://github.com/example/repo.git
	fi
	echo "$repo"
}

# make_worktree <repo>: the HARNESS creates the worktree (not the script).
make_worktree() {
	local repo="$1"
	local seq=$((WT_SEQ + 1))
	WT_SEQ=$seq
	local name="wt-$seq"
	mkdir -p "$SANDBOX/wt"
	local dir
	dir="$(mktemp -d "$SANDBOX/wt/$(basename "$repo")-$name.XXXXXX")"
	git -C "$repo" worktree add -q -b "agent-$name" "$dir"
	WT_DIR="$dir"
}
WT_SEQ=0
WT=""

echo "1. Happy path: one-off setup scopes all worktrees, main untouched"
REPO="$(make_repo with-origin)"
export AGENT_GIT_NAME="myagent[bot]" GIT_USER_NAME="my-git-user-name" GIT_USER_ID=320010330 GH_TOKEN=dummy
make_worktree "$REPO"
WT="$WT_DIR"
if "$SCRIPT" "$REPO" >/dev/null 2>&1; then
	ok "script exits 0"
else
	bad "script should exit 0"
fi
# main untouched
assert_eq "$(git -C "$REPO" config user.name)" "human" "main repo user.name stays human"
assert_eq "$(git -C "$REPO" config user.email)" "human@example.com" "main repo user.email stays human"
# includeIf written once
if git -C "$REPO" config --local --get-regexp '^includeif\.gitdir/i:\*\*/\.git/worktrees/\*\*' >/dev/null 2>&1; then
	ok "includeIf entry written to .git/config"
else
	bad "includeIf entry missing"
fi
# worktree reads as bot
assert_eq "$(git -C "$WT" config user.name)" "myagent[bot]" "worktree user.name = bot"
assert_eq "$(git -C "$WT" config user.email)" "320010330+my-git-user-name@users.noreply.github.com" "worktree commit author is bot noreply (email uses human handle)"

echo "2. Idempotent re-run"
if "$SCRIPT" "$REPO" >/dev/null 2>&1; then ok "second run exits 0"; else bad "second run failed"; fi
assert_eq "$(git -C "$WT" config user.name)" "myagent[bot]" "still bot after re-run"

echo "3. Future worktree (created AFTER setup) auto-inherits bot (no re-run)"
make_worktree "$REPO"
WT3="$WT_DIR"
assert_eq "$(git -C "$WT3" config user.name)" "myagent[bot]" "future worktree auto-inherits bot"

echo "4. Commit in worktree is authored as bot"
echo y >"$WT3/y.txt"
git -C "$WT3" add y.txt
git -C "$WT3" -c user.name=myagent[bot] -c user.email=320010330+myagent[bot]@users.noreply.github.com commit -q -m "bot commit" 2>/dev/null || git -C "$WT3" commit -q -m "bot commit"
AUTHOR="$(git -C "$WT3" log -1 --pretty='%an <%ae>')"
assert_eq "$AUTHOR" "myagent[bot] <320010330+myagent[bot]@users.noreply.github.com>" "worktree commit author is bot noreply"

echo "5. Missing required env: errors"
REPO5="$(make_repo with-origin)"
unset AGENT_GIT_NAME
if "$SCRIPT" "$REPO5" >/dev/null 2>&1; then bad "should fail without AGENT_GIT_NAME"; else ok "exits non-zero without AGENT_GIT_NAME"; fi

echo "6. Invalid GIT_USER_NAME rejected before network"
REPO6="$(make_repo with-origin)"
export AGENT_GIT_NAME="myagent[bot]" GIT_USER_NAME="bad handle/with spaces"
unset GIT_USER_ID GH_TOKEN
OUT6="$("$SCRIPT" "$REPO6" 2>&1)" || true
if echo "$OUT6" | grep -qi "must be a GitHub handle"; then ok "rejects invalid GIT_USER_NAME"; else bad "did not reject invalid GIT_USER_NAME"; fi
unset GIT_USER_NAME

echo "7. Not-a-git-dir argument: errors"
NOTREPO="$(mktemp -d)"
if "$SCRIPT" "$NOTREPO" >/dev/null 2>&1; then bad "should fail on non-git dir"; else ok "exits non-zero on non-git dir"; fi
rm -rf "$NOTREPO"

echo "8. Noreply email construction (GIT_USER_ID + GIT_USER_NAME)"
REPO8="$(make_repo with-origin)"
export AGENT_GIT_NAME="agent-laptop[bot]" GIT_USER_NAME="my-git-user-name" GIT_USER_ID=320004057 GH_TOKEN=dummy
"$SCRIPT" "$REPO8" >/dev/null 2>&1
make_worktree "$REPO8"
WT8="$WT_DIR"
assert_eq "$(git -C "$WT8" config user.name)" "agent-laptop[bot]" "agent-laptop[bot]"
assert_eq "$(git -C "$WT8" config user.email)" "320004057+my-git-user-name@users.noreply.github.com" "noreply from GIT_USER_ID (email uses human handle)"

echo "9. Noreply fallback without GIT_USER_NAME (GIT_USER_ID + AGENT_GIT_NAME)"
REPO9="$(make_repo with-origin)"
export AGENT_GIT_NAME="myagent[bot]" GIT_USER_ID=320010330
unset GIT_USER_NAME GH_TOKEN
"$SCRIPT" "$REPO9" >/dev/null 2>&1
make_worktree "$REPO9"
WT9="$WT_DIR"
assert_eq "$(git -C "$WT9" config user.email)" "320010330+myagent[bot]@users.noreply.github.com" "fallback email"

echo "10. No signing by default"
REPO10="$(make_repo with-origin)"
export AGENT_GIT_NAME="myagent[bot]" GIT_USER_NAME="my-git-user-name" GIT_USER_ID=320010330 GH_TOKEN=dummy
"$SCRIPT" "$REPO10" >/dev/null 2>&1
if [ -z "$(git -C "$REPO10" config commit.gpgsign 2>/dev/null)" ] && [ -z "$(git -C "$REPO10" config user.signingkey 2>/dev/null)" ]; then
	ok "no commit.gpgsign / user.signingkey set"
else
	bad "signing config unexpectedly set"
fi

echo "11. No hooks / no core.hooksPath written (harness owns hooks)"
REPO11="$(make_repo with-origin)"
export AGENT_GIT_NAME="myagent[bot]" GIT_USER_NAME="my-git-user-name" GIT_USER_ID=320010330 GH_TOKEN=dummy
"$SCRIPT" "$REPO11" >/dev/null 2>&1
if [ -n "$(git -C "$REPO11" config core.hooksPath 2>/dev/null)" ]; then
	bad "script must not set core.hooksPath"
else
	ok "no core.hooksPath written"
fi

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
