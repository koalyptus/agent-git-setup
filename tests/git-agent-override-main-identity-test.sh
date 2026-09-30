#!/usr/bin/env bash
# Hermetic coverage for the opt-in main-worktree identity scripts.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETUP="$ROOT/scripts/agent-git-setup.sh"
OVERRIDE="$ROOT/scripts/agent-git-override-main-identity.sh"
SANDBOX="$(mktemp -d)"
export HOME="$SANDBOX/home"
export GIT_CONFIG_GLOBAL="$SANDBOX/global.gitconfig"
export GIT_CONFIG_NOSYSTEM=1
export AGENT_GIT_ALLOW_TMP=1
export AGENT_GIT_NAME="fixture-bot[bot]"
export AGENT_GIT_BOT_ID=123456789
mkdir -p "$HOME"
git config --global user.name global-human
git config --global user.email global@example.invalid

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok   - %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL - %s\n' "$1"; }
assert_eq() {
	if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got '$1' expected '$2')"; fi
}
cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

make_repo() {
	local path="$SANDBOX/$1"
	mkdir -p "$path"
	git init -q -b main "$path"
	printf 'initial\n' >"$path/file.txt"
	git -C "$path" add file.txt
	git -C "$path" -c user.name=seed -c user.email=seed@example.invalid commit -q -m init
	printf '%s' "$path"
}

echo "1. Explicit opt-in and bot commit in main worktree"
REPO="$(make_repo repo-local-identity)"
git -C "$REPO" config --local user.name repo-human
git -C "$REPO" config --local user.email repo-human@example.invalid
if "$SETUP" "$REPO" >/dev/null 2>&1; then
	ok "existing setup persists bot identity"
else
	bad "existing setup should succeed"
fi
WT="$SANDBOX/linked-worktree"
git -C "$REPO" worktree add -q -b agent-linked "$WT"
assert_eq "$(git -C "$WT" config user.name)" "$AGENT_GIT_NAME" "linked worktree inherits bot identity before override"
if "$OVERRIDE" "$REPO" >/dev/null 2>&1; then
	bad "override must require explicit confirmation"
else
	ok "override requires confirmation"
fi
if "$OVERRIDE" --confirm "$REPO" >/dev/null 2>&1; then
	ok "override succeeds after confirmation"
else
	bad "override should succeed"
fi
assert_eq "$(git -C "$REPO" config --file "$REPO/.git/config" --get user.name)" "$AGENT_GIT_NAME" "bot name is repo-local"
assert_eq "$(git -C "$REPO" config --global user.name)" "global-human" "global name remains unchanged"
assert_eq "$(git -C "$WT" config user.name)" "$AGENT_GIT_NAME" "linked worktree remains bot-attributed during override"
printf 'bot commit\n' >>"$REPO/file.txt"
git -C "$REPO" add file.txt
git -C "$REPO" commit -q -m bot-main-commit
assert_eq "$(git -C "$REPO" log -1 --pretty='%an <%ae>')" "$AGENT_GIT_NAME <123456789+fixture-bot[bot]@users.noreply.github.com>" "main-worktree commit is bot-attributed"

echo "2. Operation rejects linked worktrees and missing setup identity"
WT_REJECT="$SANDBOX/linked-worktree-reject"
git -C "$REPO" worktree add -q -b linked-reject "$WT_REJECT"
if "$OVERRIDE" --confirm "$WT_REJECT" >/dev/null 2>&1; then bad "override must reject linked worktree"; else ok "override rejects linked worktree"; fi
REPO_UNCONFIGURED="$(make_repo repo-unconfigured)"
if "$OVERRIDE" --confirm "$REPO_UNCONFIGURED" >/dev/null 2>&1; then bad "override must require agent-git-setup"; else ok "override requires persisted setup identity"; fi

printf '\n%d passed; %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]