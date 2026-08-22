#!/usr/bin/env bash
#
# agent-git-setup-test.sh
#
# Hermetic tests for agent-git-setup.sh. Creates throwaway git repos under
# mktemp, sands HOME/GIT_CONFIG_GLOBAL to a temp dir, uses a dummy token and a
# fake origin URL (no network), and removes everything on exit.
#
set -uo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../agent-git-setup.sh"

# Sandbox: real HOME / global git config never touched.
SANDBOX="$(mktemp -d)"
export HOME="$SANDBOX"
export GIT_CONFIG_GLOBAL="$SANDBOX/.gitconfig"
export GIT_CONFIG_NOSYSTEM=1

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

# assert_eq <actual> <expected> <label>
assert_eq() {
	if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got [$1], want [$2])"; fi
}

# make_repo [with-origin]: throwaway repo with a human identity + optional origin.
make_repo() {
	local dir
	dir="$(mktemp -d)"
	git init -q -b main "$dir"
	git -C "$dir" config user.name human
	git -C "$dir" config user.email human@example.com
	echo x >"$dir/file.txt"
	git -C "$dir" add file.txt
	git -C "$dir" -c user.name=human -c user.email=human@example.com commit -q -m init
	if [ "${1:-}" = "with-origin" ]; then
		git -C "$dir" remote add origin https://github.com/example/repo.git
	fi
	echo "$dir"
}

cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

# 1. Happy path: worktree created, bot identity set, origin unchanged
echo "happy path"
REPO="$(make_repo with-origin)"
export GH_TOKEN=dummy_token
export AGENT_GIT_NAME="myagent[bot]"
export GIT_USER_ID=268339505
if "$SCRIPT" "$REPO" agent testbranch >/dev/null 2>&1; then
	WT="$REPO/.worktrees/agent"
	if [ -e "$WT/.git" ]; then ok "worktree created"; else bad "worktree not created"; fi
	assert_eq "$(git -C "$WT" config user.name)" "myagent[bot]" "worktree user.name = bot"
	assert_eq "$(git -C "$WT" config user.email)" "268339505+myagent[bot]@users.noreply.github.com" "worktree user.email = bot noreply"
	# The worktree shares the main remote; origin is NOT rewritten.
	assert_eq "$(git -C "$WT" remote get-url origin)" "https://github.com/example/repo.git" "worktree origin unchanged"
else
	bad "script exited non-zero on happy path"
fi

# 2. Main tree untouched
echo "main tree untouched"
assert_eq "$(git -C "$REPO" config user.name)" "human" "main user.name still human"
assert_eq "$(git -C "$REPO" remote get-url origin)" "https://github.com/example/repo.git" "main origin unchanged"

# 3. Idempotent re-run
echo "idempotent re-run"
if "$SCRIPT" "$REPO" agent testbranch >/dev/null 2>&1; then
	ok "second run exits 0"

	assert_eq "$(git -C "$WT" config user.name)" "myagent[bot]" "identity still bot after re-run"
else
	bad "second run exited non-zero"
fi

# 4. No-origin repo: warns, does not crash, identity still set
echo "no-origin repo"
REPO2="$(make_repo)"
export GH_TOKEN=dummy_token
export AGENT_GIT_NAME="myagent[bot]"
export GIT_USER_ID=268339505
if "$SCRIPT" "$REPO2" agent testbranch >/dev/null 2>&1; then
	WT2="$REPO2/.worktrees/agent"
	assert_eq "$(git -C "$WT2" config user.name)" "myagent[bot]" "identity set even without origin"
else
	bad "script failed on no-origin repo"
fi

# 5. Missing required env: errors with message, non-zero exit
echo "missing env"
REPO3="$(make_repo with-origin)"
unset AGENT_GIT_NAME
export GIT_USER_ID=268339505 GH_TOKEN=dummy_token
if "$SCRIPT" "$REPO3" agent testbranch 2>/dev/null; then
	bad "script should fail without AGENT_GIT_NAME"
else
	rc=$?
	if [ "$rc" -ne 0 ]; then ok "exits non-zero without AGENT_GIT_NAME"; else bad "exit code wrong"; fi
fi
unset GIT_USER_ID GIT_USER_NAME
export AGENT_GIT_NAME="myagent[bot]" GH_TOKEN=dummy_token
if "$SCRIPT" "$REPO3" agent testbranch 2>/dev/null; then
	bad "script should fail without GIT_USER_NAME/GIT_USER_ID"
else
	rc=$?
	if [ "$rc" -ne 0 ]; then ok "exits non-zero without GIT_USER_NAME/GIT_USER_ID"; else bad "exit code wrong"; fi
fi
# GH_TOKEN is now optional for the commit-author path (public GET /users/<handle>)
unset GH_TOKEN
export AGENT_GIT_NAME="myagent[bot]" GIT_USER_ID=268339505
if "$SCRIPT" "$REPO3" agent testbranch >/dev/null 2>&1; then
	ok "succeeds without GH_TOKEN when GIT_USER_ID set (GH_TOKEN optional)"
else
	bad "should succeed without GH_TOKEN when GIT_USER_ID is set"
fi

# 6. Not-a-git-dir argument: errors, exit 2
echo "not-a-git-dir"
NOTREPO="$(mktemp -d)"
export GH_TOKEN=dummy_token AGENT_GIT_NAME="myagent[bot]" GIT_USER_ID=268339505
"$SCRIPT" "$NOTREPO" agent testbranch >/dev/null 2>&1
rc=$?
assert_eq "$rc" "2" "exits 2 on non-git dir"

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
