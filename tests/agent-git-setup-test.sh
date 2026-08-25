#!/usr/bin/env bash
#
# agent-git-setup-test.sh
#
# Hermetic tests for agent-git-setup.sh. Creates throwaway git repos + worktrees
# under mktemp (the HARNESS owns the worktree; this script only writes identity),
# sands HOME/GIT_CONFIG_GLOBAL to a temp dir, uses a dummy token and a fake
# origin URL (no network), and removes everything on exit.
#
set -uo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../scripts/agent-git-setup.sh"

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
	if [ "$1" = "$2" ]; then ok "$1"; else bad "$3 (got [$1], want [$2])"; fi
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

# make_worktree <repo>: the HARNESS creates the worktree (not the script) and
# enables extensions.worktreeConfig in the MAIN repo — just like a real harness
# would. Sets the global WT to the worktree path. (Must NOT be called in a
# command substitution — $(...) runs in a subshell and loses the WT_SEQ counter.)
WT_SEQ=0
WT=""
make_worktree() {
	local repo="$1"
	WT_SEQ=$((WT_SEQ + 1))
	local name="wt-$WT_SEQ"
	git -C "$repo" config extensions.worktreeConfig true
	git -C "$repo" worktree add -q -b "agent-$name" "$SANDBOX/wt/$name"
	WT="$SANDBOX/wt/$name"
}

cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

# 1. Happy path: script writes bot identity into a harness-made worktree
echo "happy path"
REPO="$(make_repo with-origin)"
make_worktree "$REPO"
export GH_TOKEN=dummy_token
export AGENT_GIT_NAME="myagent[bot]"
export GIT_USER_ID=268339505
export GIT_USER_NAME=my-git-user-name
export AGENT_GIT_BOT_ID=320010330
if "$SCRIPT" "$WT" >/dev/null 2>&1; then
	assert_eq "$(git -C "$WT" config user.name)" "myagent[bot]" "worktree user.name = bot"
	assert_eq "$(git -C "$WT" config user.email)" "320010330+myagent[bot]@users.noreply.github.com" "worktree user.email = bot noreply"
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
if "$SCRIPT" "$WT" >/dev/null 2>&1; then
	ok "second run exits 0"
	assert_eq "$(git -C "$WT" config user.name)" "myagent[bot]" "identity still bot after re-run"
else
	bad "second run exited non-zero"
fi

# 4. Refuses to run in the MAIN repo (not a worktree) — would leak identity
echo "refuses main repo"
REPO4="$(make_repo with-origin)"
git -C "$REPO4" config extensions.worktreeConfig true
export AGENT_GIT_NAME="myagent[bot]" GIT_USER_ID=268339505
if "$SCRIPT" "$REPO4" >/dev/null 2>&1; then
	bad "script must refuse to run in the main repo"
else
	rc=$?
	if [ "$rc" -ne 0 ]; then ok "exits non-zero in main repo (no leak)"; else bad "exit code wrong"; fi
fi

# 5. Missing worktreeConfig extension: errors + tells agent to ASK HUMAN
echo "missing worktreeConfig"
REPO5="$(make_repo with-origin)"
WT5="$(git -C "$REPO5" worktree add -q -b agent-wt5 "$SANDBOX/wt/wt5" && echo "$SANDBOX/wt/wt5")"
git -C "$REPO5" config --unset extensions.worktreeConfig 2>/dev/null || true
export AGENT_GIT_NAME="myagent[bot]" GIT_USER_ID=268339505
OUT5="$("$SCRIPT" "$WT5" 2>&1)" || true
if echo "$OUT5" | grep -qi "ASK THE HUMAN"; then
	ok "prompts agent to ask human about worktreeConfig"
else
	bad "did not tell agent to ask human about worktreeConfig"
fi

# 6. Missing required env: errors with message, non-zero exit
echo "missing env"
REPO6="$(make_repo with-origin)"
make_worktree "$REPO6"
WT6="$WT"
unset AGENT_GIT_NAME
export GIT_USER_ID=268339505 GH_TOKEN=dummy_token
if "$SCRIPT" "$WT6" 2>/dev/null; then
	bad "script should fail without AGENT_GIT_NAME"
else
	rc=$?
	if [ "$rc" -ne 0 ]; then ok "exits non-zero without AGENT_GIT_NAME"; else bad "exit code wrong"; fi
fi
unset GIT_USER_ID GIT_USER_NAME
export AGENT_GIT_NAME="myagent[bot]" GH_TOKEN=dummy_token
if "$SCRIPT" "$WT6" 2>/dev/null; then
	bad "script should fail without GIT_USER_NAME/GIT_USER_ID"
else
	rc=$?
	if [ "$rc" -ne 0 ]; then ok "exits non-zero without GIT_USER_NAME/GIT_USER_ID"; else bad "exit code wrong"; fi
fi
# GH_TOKEN is now optional for the commit-author path (public GET /users/<handle>)
unset GH_TOKEN
export AGENT_GIT_NAME="myagent[bot]" GIT_USER_ID=268339505
if "$SCRIPT" "$WT6" >/dev/null 2>&1; then
	ok "succeeds without GH_TOKEN when GIT_USER_ID set (GH_TOKEN optional)"
else
	bad "should succeed without GH_TOKEN when GIT_USER_ID is set"
fi

# 7. Not-a-git-dir argument: errors, exit 2
echo "not-a-git-dir"
NOTREPO="$(mktemp -d)"
export GH_TOKEN=dummy_token AGENT_GIT_NAME="myagent[bot]" GIT_USER_ID=268339505
"$SCRIPT" "$NOTREPO" >/dev/null 2>&1
rc=$?
assert_eq "$rc" "2" "exits 2 on non-git dir"

# 8. Email uses bot noreply so agent name shows in commit list
echo "noreply email construction"
REPO8="$(make_repo with-origin)"
make_worktree "$REPO8"
WT8="$WT"
unset GH_TOKEN
export AGENT_GIT_NAME="agent-laptop[bot]" GIT_USER_ID=268339505 GIT_USER_NAME=my-git-user-name AGENT_GIT_BOT_ID=320004057
if "$SCRIPT" "$WT8" >/dev/null 2>&1; then
	assert_eq "$(git -C "$WT8" config user.name)" "agent-laptop[bot]" "email test: user.name still the bot"
	assert_eq "$(git -C "$WT8" config user.email)" "320004057+agent-laptop[bot]@users.noreply.github.com" "email uses bot noreply (id+botname@...)"
else
	bad "email construction test: script failed unexpectedly"
fi
unset AGENT_GIT_BOT_ID

# 9. Fallback when only GIT_USER_ID is set (hermetic, no GIT_USER_NAME)
echo "noreply fallback without GIT_USER_NAME"
REPO9="$(make_repo with-origin)"
make_worktree "$REPO9"
WT9="$WT"
unset GIT_USER_NAME
export GH_TOKEN=dummy_token AGENT_GIT_NAME="myagent[bot]" GIT_USER_ID=268339505 AGENT_GIT_BOT_ID=320010330
if "$SCRIPT" "$WT9" >/dev/null 2>&1; then
	assert_eq "$(git -C "$WT9" config user.email)" "320010330+myagent[bot]@users.noreply.github.com" "fallback: email uses bot noreply when GIT_USER_NAME unset"
else
	bad "fallback test: script failed unexpectedly"
fi
unset AGENT_GIT_BOT_ID

# 10. No signing by default (industry standard)
echo "no signing by default"
REPO10="$(make_repo with-origin)"
make_worktree "$REPO10"
WT10="$WT"
export GH_TOKEN=dummy_token AGENT_GIT_NAME="myagent[bot]" GIT_USER_ID=268339505 GIT_USER_NAME=my-git-user-name
if "$SCRIPT" "$WT10" >/dev/null 2>&1; then
	if git -C "$WT10" config commit.gpgsign >/dev/null 2>&1; then
		bad "commit.gpgsign should not be set by default"
	else
		ok "no commit.gpgsign by default"
	fi
	if git -C "$WT10" config user.signingkey >/dev/null 2>&1; then
		bad "user.signingkey should not be set by default"
	else
		ok "no user.signingkey by default"
	fi
else
	bad "signing test: script failed unexpectedly"
fi

# 11. Actual git commit in worktree is authored as bot (local commits appear with agent identity)
echo "commit author isolation"
REPO11="$(make_repo with-origin)"
make_worktree "$REPO11"
WT11="$WT"
export GH_TOKEN=dummy_token AGENT_GIT_NAME="myagent[bot]" GIT_USER_ID=268339505 GIT_USER_NAME=my-git-user-name AGENT_GIT_BOT_ID=320010330
if "$SCRIPT" "$WT11" >/dev/null 2>&1; then
	echo "hello" >"$WT11/hello.txt"
	git -C "$WT11" add hello.txt
	git -C "$WT11" commit -q -m "test commit as bot"
	AUTHOR="$(git -C "$WT11" log -1 --format='%an %ae')"
	assert_eq "$AUTHOR" "myagent[bot] 320010330+myagent[bot]@users.noreply.github.com" "worktree commit author is bot noreply"
	MAIN_AUTHOR="$(git -C "$REPO11" log -1 --format='%an %ae')"
	assert_eq "$MAIN_AUTHOR" "human human@example.com" "main tree commit still human"
else
	bad "commit isolation test: setup failed"
fi
unset AGENT_GIT_BOT_ID

# 12. No hooks / no core.hooksPath written (harness owns hooks)
echo "no hook interference"
REPO12="$(make_repo with-origin)"
make_worktree "$REPO12"
WT12="$WT"
export GH_TOKEN=dummy_token AGENT_GIT_NAME="myagent[bot]" GIT_USER_ID=268339505 GIT_USER_NAME=my-git-user-name AGENT_GIT_BOT_ID=320010330
if "$SCRIPT" "$WT12" >/dev/null 2>&1; then
	if [ -n "$(git -C "$WT12" config core.hooksPath 2>/dev/null)" ]; then
		bad "script must not set core.hooksPath (would override harness hooks)"
	else
		ok "no core.hooksPath written"
	fi
	if [ -e "$WT12/../.hooks/pre-commit" ]; then
		bad "script must not install guard hooks"
	else
		ok "no guard hooks installed"
	fi
else
	bad "no-hook test: setup failed"
fi
unset AGENT_GIT_BOT_ID

echo

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
