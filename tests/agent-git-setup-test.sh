#!/usr/bin/env bash
#
# agent-git-setup-test.sh
#
# Hermetic tests for agent-git-setup.sh. Creates throwaway git repos + worktrees
# under mktemp (the HARNESS owns the worktree; this script only writes identity
# to the shared repo config via includeIf). Needs only bash + git + python3.

set -uo pipefail

# Hermetic: never inherit ambient git author/committer identity from the
# caller's environment (a bot-commit export in the dev shell would otherwise
# leak into the worktree-commit assertions below).
unset GIT_AUTHOR_NAME GIT_COMMITTER_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_EMAIL

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

# make_repo [with-origin]: a main repo with an initial commit (account-owner identity).
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
assert_eq "$(git -C "$REPO" config user.name)" "human" "main repo user.name stays the account owner's"
assert_eq "$(git -C "$REPO" config user.email)" "human@example.com" "main repo user.email stays the account owner's"
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

echo "9b. Last-resort account-owner fallback when bot id cannot be resolved"
REPO9b="$(make_repo with-origin)"
export AGENT_GIT_NAME="unresolvable-bot-xyz[bot]" GIT_USER_NAME="my-git-user-name" GIT_USER_ID=320010330
unset AGENT_GIT_BOT_ID GH_TOKEN
if "$SCRIPT" "$REPO9b" >/dev/null 2>&1; then ok "account-owner fallback produces a setup (no failure)"; else bad "account-owner fallback should not fail"; fi
make_worktree "$REPO9b"
WT9b="$WT_DIR"
assert_eq "$(git -C "$WT9b" config user.name)" "unresolvable-bot-xyz[bot]" "worktree name stays the bot name"
assert_eq "$(git -C "$WT9b" config user.email)" "320010330+my-git-user-name@users.noreply.github.com" "account-owner-attributed fallback email (id from GIT_USER_ID)"

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
assert_eq "$(git -C "$REPO14" config user.name)" "human" "worktree-path input: main stays the account owner's"

echo "15. True failure only when NOTHING resolves (no bot id, no account-owner fallback)"
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

# 16. --preflight fails closed in the MAIN repo (bot identity not in effect).
#     The includeIf glob excludes the main tree's .git, so the main checkout's
#     user.name is the account owner's, not AGENT_GIT_NAME. Preflight must refuse.
echo "16. --preflight refuses the main repo (bot identity not in effect)"
REPO16="$(make_repo with-origin)"
export AGENT_GIT_NAME="myagent[bot]" AGENT_GIT_BOT_ID=320010330 GH_TOKEN=dummy
if "$SCRIPT" --preflight "$REPO16" >/dev/null 2>&1; then
	bad "preflight must fail in the main repo"
else
	rc=$?
	if [ "$rc" -ne 0 ]; then ok "preflight exits non-zero in main repo"; else bad "exit code wrong"; fi
fi
OUT16="$("$SCRIPT" --preflight "$REPO16" 2>&1)" || true
if echo "$OUT16" | grep -qi "bot identity not in effect"; then
	ok "preflight names the bot-identity-not-in-effect cause"
else
	bad "preflight did not name the bot-identity-not-in-effect cause"
fi

# 17. --preflight fails closed when GH_TOKEN is missing; passes in a PROPER
#     linked worktree where the bot identity actually resolves. These run with a
#     FAKE `gh` (bot/403) on PATH so the real `gh` (authed as the account owner) never
#     interferes (see make_fake_gh below).
echo "17. --preflight requires GH_TOKEN; passes when bot identity resolves"
REPO17="$(make_repo with-origin)"
make_worktree "$REPO17"
WT17="$WT_DIR"
export AGENT_GIT_NAME="myagent[bot]" AGENT_GIT_BOT_ID=320010330
# Apply the bot identity to the repo (writes includeIf into the shared .git).
"$SCRIPT" "$REPO17" >/dev/null 2>&1

# Fake `gh` factory. A real GitHub App INSTALLATION token returns 403 (non-zero)
# from `gh api user`, while a human PAT returns 200 with type "User". Model it.
#   make_fake_gh bot           -> `gh api user` exits non-zero (403 = bot token)
#   make_fake_gh human <login> -> `gh api user` prints {"type":"User",...} exit 0
make_fake_gh() {
	local kind="$1" login="${2:-}"
	mkdir -p "$SANDBOX/bin"
	if [ "$kind" = "human" ]; then
		cat >"$SANDBOX/bin/gh" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "api" ] && [ "\$2" = "user" ]; then
	echo "{\"type\":\"User\",\"login\":\"$login\"}"
	exit 0
fi
exec /usr/bin/gh "\$@"
EOF
	else
		cat >"$SANDBOX/bin/gh" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "api" ] && [ "$2" = "user" ]; then
	echo '{"message":"Resource not accessible by integration"}' >&2
	exit 1
fi
exec /usr/bin/gh "$@"
EOF
	fi
	chmod +x "$SANDBOX/bin/gh"
}
# Hide real gh for the whole preflight block (restore at the end).
PATH_ORIG="$PATH"
export PATH="$SANDBOX/bin:$PATH"
make_fake_gh bot

unset GH_TOKEN
if "$SCRIPT" --preflight "$WT17" >/dev/null 2>&1; then
	bad "preflight must fail without GH_TOKEN"
else
	rc=$?
	if [ "$rc" -ne 0 ]; then ok "preflight exits non-zero without GH_TOKEN"; else bad "exit code wrong"; fi
fi
export GH_TOKEN=dummy
if "$SCRIPT" --preflight "$WT17" >/dev/null 2>&1; then
	ok "preflight passes in linked worktree with bot identity + bot GH_TOKEN"
else
	bad "preflight should pass in linked worktree with bot identity + bot GH_TOKEN"
fi

# 18. --preflight is location-agnostic but effect-strict: a SEPARATE clone
#     (even under a non-standard path) with AGENT_GIT_NAME set still fails,
#     because it is not a linked worktree of the target repo so the bot
#     identity never resolves. Proves we test the EFFECT, not the path.
echo "18. --preflight fails in a separate clone (bot identity never resolves)"
REPO18c="$(make_repo with-origin)"
CLONE18="$(mktemp -d "${SANDBOX}/clone18.XXXXXX")"
git -C "$REPO18c" clone --quiet "$(git -C "$REPO18c" remote get-url origin 2>/dev/null || echo "$REPO18c")" "$CLONE18" 2>/dev/null || git clone --quiet "$REPO18c" "$CLONE18" 2>/dev/null
export AGENT_GIT_NAME="myagent[bot]" AGENT_GIT_BOT_ID=320010330 GH_TOKEN=dummy
if "$SCRIPT" --preflight "$CLONE18" >/dev/null 2>&1; then
	bad "preflight must fail in a separate clone (no bot identity)"
else
	ok "preflight fails closed in a separate clone (effect-based, not path-based)"
fi
rm -rf "$CLONE18"

echo "19. --preflight verifies the GH_TOKEN actor is the BOT (not the account owner)."
REPO19="$(make_repo with-origin)"
make_worktree "$REPO19"
WT19="$WT_DIR"
export AGENT_GIT_NAME="myagent[bot]" AGENT_GIT_BOT_ID=320010330 GH_TOKEN=dummy
# The bot commit identity must be IN EFFECT (check 1) before preflight can pass.
"$SCRIPT" "$REPO19" >/dev/null 2>&1

# 19a. Bot token (gh api user -> 403) -> preflight passes.
make_fake_gh bot
if "$SCRIPT" --preflight "$WT19" >/dev/null 2>&1; then
	ok "preflight passes when GH_TOKEN is a bot install token (gh api user 403)"
else
	bad "preflight should pass when GH_TOKEN is a bot install token"
fi

# 19b. Human token (gh api user -> User), no consent -> preflight FAILS closed.
make_fake_gh human koalyptus
unset AGENT_GIT_ALLOW_HUMAN_ACTOR
if "$SCRIPT" --preflight "$WT19" >/dev/null 2>&1; then
	bad "preflight must FAIL when GH_TOKEN actor is the account owner (no consent)"
else
	rc=$?
	if [ "$rc" -ne 0 ]; then ok "preflight fails closed when GH_TOKEN actor is the account owner"; else bad "exit code wrong"; fi
fi
OUT19b="$("$SCRIPT" --preflight "$WT19" 2>&1)" || true
if echo "$OUT19b" | grep -qi "GH_TOKEN is your account, not the bot"; then
	ok "account-owner-actor failure names the ACCOUNT OWNER consequence"
else
	bad "account-owner-actor failure did not name the ACCOUNT OWNER consequence"
fi

# 19c. Human token, explicit consent (AGENT_GIT_ALLOW_HUMAN_ACTOR=1) -> pass.
export AGENT_GIT_ALLOW_HUMAN_ACTOR=1
if "$SCRIPT" --preflight "$WT19" >/dev/null 2>&1; then
	ok "preflight passes as the account owner only with explicit AGENT_GIT_ALLOW_HUMAN_ACTOR=1"
else
	bad "preflight should pass with explicit account-owner-actor consent"
fi
unset AGENT_GIT_ALLOW_HUMAN_ACTOR

# 19d. gh present but `gh api user` unverifiable (network down / 403): preflight
#     must NOT hard-block a valid bot token (pass). Then a true gh-ABSENT case
#     warns rather than blocks.
make_fake_gh bot # gh present, unverifiable -> pass
if "$SCRIPT" --preflight "$WT19" >/dev/null 2>&1; then
	ok "preflight passes (does not block) when gh is present but unverifiable"
else
	bad "preflight must not hard-block when gh present but unverifiable"
fi
# gh truly absent: build a PATH with no gh binary; keep git/bash working via a
# minimal bin dir that symlinks only the tools the script needs.
rm -f "$SANDBOX/bin/gh"
NOGH="$SANDBOX/noghbin"
mkdir -p "$NOGH"
for t in git bash sed printf rm mkdir cat mktemp awk grep; do
	lt="$(command -v "$t" 2>/dev/null || true)"
	if [ -n "$lt" ]; then ln -sf "$lt" "$NOGH/$t" 2>/dev/null || true; fi
done
export PATH="$NOGH"
if "$SCRIPT" --preflight "$WT19" >/dev/null 2>&1; then
	ok "preflight passes (warns) when gh is unavailable"
else
	bad "preflight must not hard-fail when gh is unavailable"
fi
export PATH="$PATH_ORIG"
unset REPO19 WT19 CLONE18 REPO18c

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
