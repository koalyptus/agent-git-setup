#!/usr/bin/env bash
#
# agent-git-setup-test.sh
#
# Hermetic tests for agent-git-setup.sh. Creates throwaway git repos under
# mktemp, sands HOME/GIT_CONFIG_GLOBAL to a temp dir, uses a dummy token and a
# fake origin URL (no network), and removes everything on exit.
#
set -uo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/agent-git-setup.sh"

# Sandbox: real HOME / global git config never touched.
SANDBOX="$(mktemp -d)"
export HOME="$SANDBOX"
export GIT_CONFIG_GLOBAL="$SANDBOX/.gitconfig"
export GIT_CONFIG_NOSYSTEM=1

PASS=0
FAIL=0

ok()  { echo "  ok   - $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL - $1"; FAIL=$((FAIL+1)); }

# Helper: make a throwaway repo with a human identity and (optionally) an origin.
make_repo() {
  local dir; dir="$(mktemp -d)"
  git init -q -b main "$dir"
  git -C "$dir" config user.name human
  git -C "$dir" config user.email human@example.com
  echo x > "$dir/file.txt"
  git -C "$dir" add file.txt
  git -C "$dir" -c user.name=human -c user.email=human@example.com commit -q -m init
  if [ "${1:-}" = "with-origin" ]; then
    git -C "$dir" remote add origin https://github.com/example/repo.git
  fi
  echo "$dir"
}

cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

# 1. Happy path: worktree created, bot identity set, origin rewritten
echo "happy path"
REPO="$(make_repo with-origin)"
export GH_TOKEN=dummy_token
export AGENT_GIT_NAME="myagent[bot]"
export AGENT_GIT_USER_ID=268339505
if "$SCRIPT" "$REPO" agent testbranch >/dev/null 2>&1; then
  WT="$REPO/.worktrees/agent"
  [ -e "$WT/.git" ] && ok "worktree created" || bad "worktree not created"
  # Read the worktree's OWN config file (git -C $WT resolves to main repo).
  WT_CFG="$REPO/.git/worktrees/agent/config"
  [ "$(git config -f "$WT_CFG" user.name)" = "myagent[bot]" ] && ok "worktree user.name = bot" || bad "worktree user.name wrong"
  [ "$(git config -f "$WT_CFG" user.email)" = "268339505+myagent[bot]@users.noreply.github.com" ] && ok "worktree user.email = bot noreply" || bad "worktree user.email wrong"
  # Model X: origin is NOT rewritten; the worktree shares the main remote.
  case "$(git -C "$WT" remote get-url origin)" in
    https://github.com/example/repo.git) ok "worktree origin unchanged (model X)" ;;
    *) bad "worktree origin was rewritten (should not be, model X)" ;;
  esac
else
  bad "script exited non-zero on happy path"
fi

# 2. Main tree untouched
echo "main tree untouched"
[ "$(git -C "$REPO" config user.name)" = "human" ] && ok "main user.name still human" || bad "main user.name changed"
case "$(git -C "$REPO" remote get-url origin)" in
  https://github.com/example/repo.git) ok "main origin unchanged" ;;
  *) bad "main origin changed" ;;
esac

# 3. Idempotent re-run
echo "idempotent re-run"
if "$SCRIPT" "$REPO" agent testbranch >/dev/null 2>&1; then
  ok "second run exits 0"
  WT="$REPO/.worktrees/agent"
  WT_CFG="$REPO/.git/worktrees/agent/config"
  [ "$(git config -f "$WT_CFG" user.name)" = "myagent[bot]" ] && ok "identity still bot after re-run" || bad "identity lost after re-run"
else
  bad "second run exited non-zero"
fi

# 4. No-origin repo: warns, does not crash
echo "no-origin repo"
REPO2="$(make_repo)"
export GH_TOKEN=dummy_token
export AGENT_GIT_NAME="myagent[bot]"
export AGENT_GIT_USER_ID=268339505
if "$SCRIPT" "$REPO2" agent testbranch >/dev/null 2>&1; then
  WT="$REPO2/.worktrees/agent"
  WT_CFG="$REPO2/.git/worktrees/agent/config"
  [ "$(git config -f "$WT_CFG" user.name)" = "myagent[bot]" ] && ok "identity set even without origin" || bad "identity not set without origin"
else
  bad "script failed on no-origin repo"
fi

# 5. Missing required env: errors with message, non-zero exit
echo "missing env"
REPO3="$(make_repo with-origin)"
unset GH_TOKEN AGENT_GIT_NAME AGENT_GIT_USER_ID
if "$SCRIPT" "$REPO3" agent testbranch 2>/dev/null; then
  bad "script should fail without required env"
else
  [ $? -ne 0 ] && ok "exits non-zero without required env" || bad "exit code wrong"
fi

# 6. Not-a-git-dir argument: errors, exit 2
echo "not-a-git-dir"
NOTREPO="$(mktemp -d)"
export GH_TOKEN=dummy_token AGENT_GIT_NAME="myagent[bot]" AGENT_GIT_USER_ID=268339505
"$SCRIPT" "$NOTREPO" agent testbranch >/dev/null 2>&1
rc=$?
[ $rc -eq 2 ] && ok "exits 2 on non-git dir" || bad "wrong exit code ($rc) on non-git dir"

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
