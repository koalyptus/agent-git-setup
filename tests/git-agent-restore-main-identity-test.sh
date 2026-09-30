#!/usr/bin/env bash
# Hermetic coverage for restoring the main-worktree identity.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETUP="$ROOT/scripts/agent-git-setup.sh"
OVERRIDE="$ROOT/scripts/agent-git-override-main-identity.sh"
RESTORE="$ROOT/scripts/agent-git-restore-main-identity.sh"
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

printf '%s\n' '1. Restore exact local identity and leave linked worktrees bot-attributed'
REPO="$(make_repo repo-local-identity)"
git -C "$REPO" config --local user.name repo-human
git -C "$REPO" config --local user.email repo-human@example.invalid
if "$SETUP" "$REPO" >/dev/null 2>&1; then ok 'setup persists bot identity'; else bad 'setup should succeed'; fi
WT="$SANDBOX/linked-worktree"
git -C "$REPO" worktree add -q -b linked "$WT"
if "$OVERRIDE" --confirm "$REPO" >/dev/null 2>&1; then ok 'main-worktree override succeeds'; else bad 'main-worktree override should succeed'; fi
if "$RESTORE" "$REPO" >/dev/null 2>&1; then bad 'restore must require confirmation'; else ok 'restore requires confirmation'; fi
if "$RESTORE" --confirm "$REPO" >/dev/null 2>&1; then ok 'restore succeeds'; else bad 'restore should succeed'; fi
assert_eq "$(git -C "$REPO" config --file "$REPO/.git/config" --get user.name)" 'repo-human' 'saved local name restored'
assert_eq "$(git -C "$REPO" config --file "$REPO/.git/config" --get user.email)" 'repo-human@example.invalid' 'saved local email restored'
assert_eq "$(git -C "$WT" config user.name)" "$AGENT_GIT_NAME" 'linked worktree remains bot-attributed'
if [ ! -e "$REPO/.git/agent-main-identity.backup.config" ]; then ok 'backup removed after successful restore'; else bad 'backup should be removed'; fi
printf 'human commit\n' >>"$REPO/file.txt"
git -C "$REPO" add file.txt
git -C "$REPO" commit -q -m human-main-commit
assert_eq "$(git -C "$REPO" log -1 --pretty='%an <%ae>')" 'repo-human <repo-human@example.invalid>' 'main-worktree commit returns to saved identity'

printf '%s\n' '2. Refuse to overwrite identity changes and preserve backup'
if "$OVERRIDE" --confirm "$REPO" >/dev/null 2>&1; then ok 'second override succeeds'; else bad 'second override should succeed'; fi
git -C "$REPO" config --local user.email changed@example.invalid
if "$RESTORE" --confirm "$REPO" >/dev/null 2>&1; then bad 'restore should refuse changed identity'; else ok 'restore refuses changed identity'; fi
if [ -f "$REPO/.git/agent-main-identity.backup.config" ]; then ok 'backup retained after conflict'; else bad 'backup must remain after conflict'; fi
git -C "$REPO" config --local user.name "$AGENT_GIT_NAME"
git -C "$REPO" config --local user.email '123456789+fixture-bot[bot]@users.noreply.github.com'
if "$RESTORE" --confirm "$REPO" >/dev/null 2>&1; then ok 'restore succeeds after resolving conflict'; else bad 'restore should succeed after resolving conflict'; fi

printf '%s\n' '3. Remove temporary local identity when original identity was inherited globally'
REPO_GLOBAL="$(make_repo repo-global-identity)"
if "$SETUP" "$REPO_GLOBAL" >/dev/null 2>&1; then ok 'setup for global identity fixture succeeds'; else bad 'setup should succeed'; fi
if "$OVERRIDE" --confirm "$REPO_GLOBAL" >/dev/null 2>&1; then ok 'override succeeds without prior local identity'; else bad 'override should succeed without prior local identity'; fi
if "$RESTORE" --confirm "$REPO_GLOBAL" >/dev/null 2>&1; then ok 'restore succeeds without prior local identity'; else bad 'restore should succeed without prior local identity'; fi
if git -C "$REPO_GLOBAL" config --file "$REPO_GLOBAL/.git/config" --get-all user.name >/dev/null 2>&1; then
	bad 'restore should leave user.name absent from repo config'
else
	ok 'repo-local name override removed'
fi
assert_eq "$(git -C "$REPO_GLOBAL" config user.name)" 'global-human' 'global identity is effective after restore'
assert_eq "$(git config --global user.name)" 'global-human' 'global config remains untouched'

printf '%s\n' '4. Refuse linked-worktree restore and restore without a backup'
if "$RESTORE" --confirm "$WT" >/dev/null 2>&1; then bad 'restore must reject linked worktree'; else ok 'restore rejects linked worktree'; fi
if "$RESTORE" --confirm "$REPO_GLOBAL" >/dev/null 2>&1; then bad 'restore must require a saved backup'; else ok 'restore requires saved backup'; fi

printf '\n%d passed; %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
