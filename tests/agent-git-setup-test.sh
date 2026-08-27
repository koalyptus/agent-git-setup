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
# Repos are intentionally throwaway (under $SANDBOX=/tmp); opt the hardening guard in.
export AGENT_GIT_ALLOW_TMP=1

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
export AGENT_GIT_NAME="myagent[bot]" AGENT_GIT_BOT_ID=320010330 GH_TOKEN=dummy
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
assert_eq "$(git -C "$WT" config user.email)" "320010330+myagent[bot]@users.noreply.github.com" "worktree commit author is bot noreply (email uses bot name)"

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
export AGENT_GIT_NAME="agent-laptop[bot]" AGENT_GIT_BOT_ID=320004057 GH_TOKEN=dummy
"$SCRIPT" "$REPO8" >/dev/null 2>&1
make_worktree "$REPO8"
WT8="$WT_DIR"
assert_eq "$(git -C "$WT8" config user.name)" "agent-laptop[bot]" "agent-laptop[bot]"
assert_eq "$(git -C "$WT8" config user.email)" "320004057+agent-laptop[bot]@users.noreply.github.com" "noreply from bot id (email uses bot name)"

echo "9. Noreply from bot id via AGENT_GIT_BOT_ID (no network needed)"
REPO9="$(make_repo with-origin)"
export AGENT_GIT_NAME="myagent[bot]" AGENT_GIT_BOT_ID=320010330
unset GIT_USER_NAME GH_TOKEN
"$SCRIPT" "$REPO9" >/dev/null 2>&1
make_worktree "$REPO9"
WT9="$WT_DIR"
assert_eq "$(git -C "$WT9" config user.email)" "320010330+myagent[bot]@users.noreply.github.com" "email from bot id (offline-safe)"

echo "9b. Last-resort human fallback when bot id cannot be resolved"
REPO9b="$(make_repo with-origin)"
export AGENT_GIT_NAME="unresolvable-bot-xyz[bot]" GIT_USER_NAME="my-git-user-name" GIT_USER_ID=320010330
unset AGENT_GIT_BOT_ID GH_TOKEN
if "$SCRIPT" "$REPO9b" >/dev/null 2>&1; then ok "human fallback produces a setup (no failure)"; else bad "human fallback should not fail"; fi
make_worktree "$REPO9b"
WT9b="$WT_DIR"
assert_eq "$(git -C "$WT9b" config user.name)" "unresolvable-bot-xyz[bot]" "worktree name stays the bot name"
assert_eq "$(git -C "$WT9b" config user.email)" "320010330+my-git-user-name@users.noreply.github.com" "human-attributed fallback email (id from GIT_USER_ID)"

echo "10. No signing by default"
REPO10="$(make_repo with-origin)"
export AGENT_GIT_NAME="myagent[bot]" AGENT_GIT_BOT_ID=320010330 GH_TOKEN=dummy
"$SCRIPT" "$REPO10" >/dev/null 2>&1
if [ -z "$(git -C "$REPO10" config commit.gpgsign 2>/dev/null)" ] && [ -z "$(git -C "$REPO10" config user.signingkey 2>/dev/null)" ]; then
	ok "no commit.gpgsign / user.signingkey set"
else
	bad "signing config unexpectedly set"
fi

echo "11. No hooks / no core.hooksPath written (harness owns hooks)"
REPO11="$(make_repo with-origin)"
export AGENT_GIT_NAME="myagent[bot]" AGENT_GIT_BOT_ID=320010330 GH_TOKEN=dummy
"$SCRIPT" "$REPO11" >/dev/null 2>&1
if [ -n "$(git -C "$REPO11" config core.hooksPath 2>/dev/null)" ]; then
	bad "script must not set core.hooksPath"
else
	ok "no core.hooksPath written"
fi

echo "12. Ephemeral-location guard: refuses /tmp repo without opt-in"
REPO12="$(make_repo with-origin)"
unset AGENT_GIT_ALLOW_TMP
export AGENT_GIT_NAME="myagent[bot]" GIT_USER_NAME="my-git-user-name" GIT_USER_ID=320010330
if "$SCRIPT" "$REPO12" >/dev/null 2>&1; then bad "should refuse ephemeral repo without AGENT_GIT_ALLOW_TMP"; else ok "refuses ephemeral repo"; fi
export AGENT_GIT_ALLOW_TMP=1

echo "13. Self-nesting guard: refuses when script lives inside target repo"
REPO13="$(make_repo with-origin)"
cp "$SCRIPT" "$REPO13/agent-git-setup.sh"
if bash "$REPO13/agent-git-setup.sh" "$REPO13" >/dev/null 2>&1; then bad "should refuse self-nesting"; else ok "refuses self-nesting"; fi

echo "14. Works when given a LINKED WORKTREE path (not just the main repo)"
REPO14="$(make_repo with-origin)"
make_worktree "$REPO14"
WT14="$WT_DIR"
export AGENT_GIT_ALLOW_TMP=1 AGENT_GIT_NAME="myagent[bot]" AGENT_GIT_BOT_ID=320010330
if "$SCRIPT" "$WT14" >/dev/null 2>&1; then ok "script exits 0 from worktree path"; else bad "script should exit 0 from worktree path"; fi
assert_eq "$(git -C "$WT14" config user.name)" "myagent[bot]" "worktree-path input: worktree reads bot"
assert_eq "$(git -C "$REPO14" config user.name)" "human" "worktree-path input: main stays human"

echo "15. True failure only when NOTHING resolves (no bot id, no human fallback)"
REPO15="$(make_repo with-origin)"
export AGENT_GIT_NAME="definitely-not-a-real-bot-xyz[bot]"
unset AGENT_GIT_BOT_ID GIT_USER_NAME GH_TOKEN
if "$SCRIPT" "$REPO15" >/dev/null 2>&1; then TRUE15=0; else TRUE15=$?; fi
if [ "${TRUE15:-0}" -ne 0 ]; then ok "exits non-zero when nothing resolves"; else bad "should exit non-zero when nothing resolves"; fi
if [ -f "$REPO15/.git/agent-bot-identity.config" ]; then
	bad "bot config written despite no resolvable identity"
else
	ok "no bot config file written when nothing resolves"
fi

# 16. --preflight fails closed in the MAIN repo (would attribute to human).
#     The includeIf glob excludes the main tree's .git, so a main-tree commit
#     is human-attributed. Preflight must refuse.
echo "16. --preflight refuses the main repo"
REPO16="$(make_repo with-origin)"
export AGENT_GIT_NAME="myagent[bot]" AGENT_GIT_BOT_ID=320010330 GH_TOKEN=dummy
if "$SCRIPT" --preflight "$REPO16" >/dev/null 2>&1; then
	bad "preflight must fail in the main repo"
else
	rc=$?
	if [ "$rc" -ne 0 ]; then ok "preflight exits non-zero in main repo"; else bad "exit code wrong"; fi
fi
OUT16="$("$SCRIPT" --preflight "$REPO16" 2>&1)" || true
if echo "$OUT16" | grep -qi "attributed to YOU (human)"; then
	ok "preflight names human-attribution consequence"
else
	bad "preflight did not name human-attribution consequence"
fi

# 17. --preflight fails closed when GH_TOKEN is missing, passes when present.
echo "17. --preflight requires GH_TOKEN"
REPO17="$(make_repo with-origin)"
make_worktree "$REPO17"
WT17="$WT_DIR"
export AGENT_GIT_NAME="myagent[bot]" AGENT_GIT_BOT_ID=320010330
unset GH_TOKEN
if "$SCRIPT" --preflight "$WT17" >/dev/null 2>&1; then
	bad "preflight must fail without GH_TOKEN"
else
	rc=$?
	if [ "$rc" -ne 0 ]; then ok "preflight exits non-zero without GH_TOKEN"; else bad "exit code wrong"; fi
fi
export GH_TOKEN=dummy
if "$SCRIPT" --preflight "$WT17" >/dev/null 2>&1; then
	ok "preflight passes in worktree with GH_TOKEN"
else
	bad "preflight should pass in worktree with GH_TOKEN"
fi

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
