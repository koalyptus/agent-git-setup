#!/usr/bin/env pwsh
#
# agent-git-setup-test.ps1
#
# Hermetic tests for agent-git-setup.ps1. Creates throwaway git repos +
# worktrees under $env:TEMP (the HARNESS owns the worktree; this script
# only writes identity to the shared repo config via includeIf). Needs
# only PowerShell 7+ and git.
#
# Mirrors tests/agent-git-setup-test.sh: same cases, same coverage,
# PowerShell-native (no bash, no shuf, no mktemp, no fake-gh bash heredoc).

$ErrorActionPreference = "Continue"

# Hermetic: never inherit ambient git author/committer identity from the
# caller's environment (a bot-commit export in the dev shell would otherwise
# leak into the worktree-commit assertions below).
Remove-Item env:GIT_AUTHOR_NAME, env:GIT_COMMITTER_NAME, env:GIT_AUTHOR_EMAIL, env:GIT_COMMITTER_EMAIL -ErrorAction SilentlyContinue

$ScriptDir = Split-Path -Parent (Resolve-Path $MyInvocation.MyCommand.Path)
$RepoRoot = Split-Path -Parent $ScriptDir
$Script = Join-Path $RepoRoot "scripts" "agent-git-setup.ps1"
$Sandbox = Join-Path $env:TEMP ("agent-git-setup-test-" + (Get-Date -Format "yyyyMMddHHmmssffffff"))
if (-not (Test-Path $Sandbox)) { New-Item -ItemType Directory -Path $Sandbox -Force | Out-Null }
$env:HOME = $Sandbox
$env:GIT_CONFIG_GLOBAL = Join-Path $Sandbox ".gitconfig"
$env:GIT_CONFIG_NOSYSTEM = "1"
$env:GIT_TERMINAL_PROMPT = "0"
# Repos are intentionally throwaway (under $env:TEMP); opt the hardening guard in.
$env:AGENT_GIT_ALLOW_TMP = "1"

$Pass = 0
$Fail = 0
function Ok($Name) { $Pass++; Write-Host "  ok   - $Name" -ForegroundColor Green }
function Bad($Name) { $Fail++; Write-Host "  FAIL - $Name" -ForegroundColor Red }
function AssertEq($Actual, $Expected, $Name) {
    if ($Actual -eq $Expected) { Ok $Name } else { Bad "$Name (got '$Actual' expected '$Expected')" }
}
function Cleanup { Remove-Item $Sandbox -Recurse -Force -ErrorAction SilentlyContinue }
# Cleanup on exit (best-effort; the trap below covers normal exit).
Register-ObjectEvent -InputObject (Get-EventSubscriber) -SourceIdentifier PowerShell.Exiting -Action { Cleanup } | Out-Null
try { Cleanup } catch {}

# make_repo [with-origin]: a main repo with an initial commit (account-owner identity).
$RepoSeq = 0
function MakeRepo($WithOrigin) {
    $RepoSeq++
    $Repo = Join-Path $Sandbox ("repo-" + $RepoSeq)
    Remove-Item $Repo -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $Sandbox "wt") -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path $Repo -Force | Out-Null
    & git init -q -b main "$Repo"
    & git -C "$Repo" config user.name human
    & git -C "$Repo" config user.email human@example.com
    Set-Content -Path (Join-Path $Repo "file.txt") -Value "x" -NoNewline
    & git -C "$Repo" add file.txt
    & git -C "$Repo" -c user.name=human -c user.email=human@example.com commit -q -m init
    if ($WithOrigin -eq "with-origin") {
        & git -C "$Repo" remote add origin https://github.com/example/repo.git
    }
    return $Repo
}

# make_worktree <repo>: the HARNESS creates the worktree (not the script).
$WtSeq = 0
function MakeWorktree($Repo) {
    $WtSeq++
    $Name = "wt-" + $WtSeq
    $Dir = Join-Path $Sandbox "wt" ((Split-Path $Repo -Leaf) + "-" + $Name)
    if (Test-Path $Dir) { Remove-Item $Dir -Recurse -Force }
    New-Item -ItemType Directory -Path $Dir -Force | Out-Null
    & git -C "$Repo" worktree add -q -b ("agent-" + $Name) "$Dir"
    return $Dir
}

# make_fake_gh <kind> [login]: put a fake gh on a local PATH so the real gh never interferes.
#   kind=bot        -> gh api user exits 1 (403 = bot install token)
#   kind=human login-> gh api user prints {"type":"User","login":"login"} exit 0
function MakeFakeGh($Kind, $Login = "") {
    $BinDir = Join-Path $Sandbox "bin"
    Remove-Item $BinDir -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path $BinDir -Force | Out-Null
    $GhPath = Join-Path $BinDir "gh"
    if ($Kind -eq "human") {
        $Payload = '{"type":"User","login":"' + $Login + '"}'
        $Content = @"
`$args | Out-Null
if (`$args[0] -eq 'api' -and `$args[1] -eq 'user') {
    Write-Output '$Payload'
    exit 0
}
exec /usr/bin/gh `$args
"@
        Set-Content -Path $GhPath -Value $Content -Encoding UTF8
    } else {
        $Content = @"
`$args | Out-Null
if (`$args[0] -eq 'api' -and `$args[1] -eq 'user') {
    Write-Error 'Resource not accessible by integration'
    exit 1
}
exec /usr/bin/gh `$args
"@
        Set-Content -Path $GhPath -Value $Content -Encoding UTF8
    }
    try { chmod +x $GhPath } catch {}
    return $BinDir
}

Write-Host "1. Happy path: one-off setup scopes all worktrees, main untouched"
$Repo = MakeRepo "with-origin"
$env:AGENT_GIT_NAME = "myagent[bot]"
$env:AGENT_GIT_BOT_ID = "320010330"
$env:GH_TOKEN = "dummy"
$WtDir = MakeWorktree $Repo
if (& $Script $Repo *> $null) { Ok "script exits 0" } else { Bad "script should exit 0" }
AssertEq (& git -C $Repo config user.name) "human" "main repo user.name stays the account owner's"
AssertEq (& git -C $Repo config user.email) "human@example.com" "main repo user.email stays the account owner's"
if (& git -C $Repo config --local --get-regexp '^includeif\.gitdir/i:\*\*/\.git/worktrees/\*\*.path' *> $null 2>&1) { Ok "includeIf entry written to .git/config" } else { Bad "includeIf entry missing" }
AssertEq (& git -C $WtDir config user.name) "myagent[bot]" "worktree user.name = bot"
AssertEq (& git -C $WtDir config user.email) "320010330+myagent[bot]@users.noreply.github.com" "worktree commit author is bot noreply"

Write-Host "2. Idempotent re-run"
if (& $Script $Repo *> $null) { Ok "second run exits 0" } else { Bad "second run failed" }
AssertEq (& git -C $WtDir config user.name) "myagent[bot]" "still bot after re-run"

Write-Host "3. Future worktree (created AFTER setup) auto-inherits bot (no re-run)"
$WtDir = MakeWorktree $Repo
AssertEq (& git -C $WtDir config user.name) "myagent[bot]" "future worktree auto-inherits bot"

Write-Host "4. Commit in worktree is authored as bot"
Set-Content -Path (Join-Path $WtDir "y.txt") -Value "y" -NoNewline
& git -C $WtDir add y.txt
& git -C $WtDir -c user.name=myagent[bot] -c user.email=320010330+myagent[bot]@users.noreply.github.com commit -q -m "bot commit" 2>$null
$Author = & git -C $WtDir log -1 --pretty='%an <%ae>'
AssertEq $Author "myagent[bot] <320010330+myagent[bot]@users.noreply.github.com>" "worktree commit author is bot noreply"

Write-Host "5. Missing required env: errors"
$Repo5 = MakeRepo "with-origin"
Remove-Item env:AGENT_GIT_NAME -ErrorAction SilentlyContinue
$Rc = 0
try { & $Script $Repo5 *> $null } catch { $Rc = $LASTEXITCODE }
if ($Rc -ne 0) { Ok "exits non-zero without AGENT_GIT_NAME" } else { Bad "should fail without AGENT_GIT_NAME" }

Write-Host "6. Invalid GIT_USER_NAME rejected before network"
$Repo6 = MakeRepo "with-origin"
$env:AGENT_GIT_NAME = "myagent[bot]"
$env:GIT_USER_NAME = "bad handle/with spaces"
Remove-Item env:GIT_USER_ID -ErrorAction SilentlyContinue
Remove-Item env:GH_TOKEN -ErrorAction SilentlyContinue
$Out6 = & $Script $Repo6 2>&1
if ($Out6 -match "must be a GitHub handle") { Ok "rejects invalid GIT_USER_NAME" } else { Bad "did not reject invalid GIT_USER_NAME" }
Remove-Item env:GIT_USER_NAME -ErrorAction SilentlyContinue

Write-Host "7. Not-a-git-dir argument: errors"
$NotRepo = Join-Path $Sandbox "notarepo"
New-Item -ItemType Directory -Path $NotRepo -Force | Out-Null
$Rc = 0
try { & $Script $NotRepo *> $null } catch { $Rc = $LASTEXITCODE }
if ($Rc -ne 0) { Ok "exits non-zero on non-git dir" } else { Bad "should exit non-zero on non-git dir" }

Write-Host "8. Noreply email construction (GIT_USER_ID + GIT_USER_NAME)"
$Repo8 = MakeRepo "with-origin"
$env:AGENT_GIT_NAME = "agent-laptop[bot]"
$env:AGENT_GIT_BOT_ID = "320004057"
$env:GH_TOKEN = "dummy"
& $Script $Repo8 *> $null
$WtDir = MakeWorktree $Repo8
AssertEq (& git -C $WtDir config user.name) "agent-laptop[bot]" "agent-laptop[bot]"
AssertEq (& git -C $WtDir config user.email) "320004057+agent-laptop[bot]@users.noreply.github.com" "noreply from bot id (email uses bot name)"

Write-Host "9. Noreply from bot id via AGENT_GIT_BOT_ID (no network needed)"
$Repo9 = MakeRepo "with-origin"
$env:AGENT_GIT_NAME = "myagent[bot]"
$env:AGENT_GIT_BOT_ID = "320010330"
Remove-Item env:GIT_USER_NAME -ErrorAction SilentlyContinue
Remove-Item env:GH_TOKEN -ErrorAction SilentlyContinue
& $Script $Repo9 *> $null
$WtDir = MakeWorktree $Repo9
AssertEq (& git -C $WtDir config user.email) "320010330+myagent[bot]@users.noreply.github.com" "email from bot id (offline-safe)"

Write-Host "9b. Last-resort account-owner fallback when bot id cannot be resolved"
$Repo9b = MakeRepo "with-origin"
$env:AGENT_GIT_NAME = "unresolvable-bot-xyz[bot]"
$env:GIT_USER_NAME = "my-git-user-name"
$env:GIT_USER_ID = "320010330"
Remove-Item env:AGENT_GIT_BOT_ID -ErrorAction SilentlyContinue
Remove-Item env:GH_TOKEN -ErrorAction SilentlyContinue
$Rc = 0
try { & $Script $Repo9b *> $null } catch { $Rc = $LASTEXITCODE }
if ($Rc -eq 0) { Ok "account-owner fallback produces a setup (no failure)" } else { Bad "account-owner fallback should not fail" }
$WtDir = MakeWorktree $Repo9b
AssertEq (& git -C $WtDir config user.name) "unresolvable-bot-xyz[bot]" "worktree name stays the bot name"
AssertEq (& git -C $WtDir config user.email) "320010330+my-git-user-name@users.noreply.github.com" "account-owner-attributed fallback email"

Write-Host "10. No signing by default"
$Repo10 = MakeRepo "with-origin"
$env:AGENT_GIT_NAME = "myagent[bot]"
$env:AGENT_GIT_BOT_ID = "320010330"
$env:GH_TOKEN = "dummy"
& $Script $Repo10 *> $null
if (-not (& git -C $Repo10 config commit.gpgsign 2>$null) -and -not (& git -C $Repo10 config user.signingkey 2>$null)) { Ok "no commit.gpgsign / user.signingkey set" } else { Bad "signing config unexpectedly set" }

Write-Host "11. No hooks / no core.hooksPath written (harness owns hooks)"
$Repo11 = MakeRepo "with-origin"
$env:AGENT_GIT_NAME = "myagent[bot]"
$env:AGENT_GIT_BOT_ID = "320010330"
$env:GH_TOKEN = "dummy"
& $Script $Repo11 *> $null
if (& git -C $Repo11 config core.hooksPath 2>$null) { Bad "script must not set core.hooksPath" } else { Ok "no core.hooksPath written" }

Write-Host "12. Ephemeral-location guard: refuses without opt-in"
$Repo12 = MakeRepo "with-origin"
Remove-Item env:AGENT_GIT_ALLOW_TMP -ErrorAction SilentlyContinue
$env:AGENT_GIT_NAME = "myagent[bot]"
$env:GIT_USER_NAME = "my-git-user-name"
$env:GIT_USER_ID = "320010330"
$Rc = 0
try { & $Script $Repo12 *> $null } catch { $Rc = $LASTEXITCODE }
if ($Rc -ne 0) { Ok "refuses ephemeral repo without AGENT_GIT_ALLOW_TMP" } else { Bad "should refuse ephemeral repo" }
$env:AGENT_GIT_ALLOW_TMP = "1"

Write-Host "13. Self-nesting guard: refuses when script lives inside target repo"
$Repo13 = MakeRepo "with-origin"
Copy-Item $Script (Join-Path $Repo13 "agent-git-setup.ps1")
$Rc = 0
try { & (Join-Path $Repo13 "agent-git-setup.ps1") $Repo13 *> $null } catch { $Rc = $LASTEXITCODE }
if ($Rc -ne 0) { Ok "refuses self-nesting" } else { Bad "should refuse self-nesting" }
Remove-Item (Join-Path $Repo13 "agent-git-setup.ps1") -Force -ErrorAction SilentlyContinue

Write-Host "14. Works when given a LINKED WORKTREE path (not just the main repo)"
$Repo14 = MakeRepo "with-origin"
$WtDir = MakeWorktree $Repo14
$env:AGENT_GIT_ALLOW_TMP = "1"
$env:AGENT_GIT_NAME = "myagent[bot]"
$env:AGENT_GIT_BOT_ID = "320010330"
$Rc = 0
try { & $Script $WtDir *> $null } catch { $Rc = $LASTEXITCODE }
if ($Rc -eq 0) { Ok "script exits 0 from worktree path" } else { Bad "script should exit 0 from worktree path" }
AssertEq (& git -C $WtDir config user.name) "myagent[bot]" "worktree-path input: worktree reads bot"
AssertEq (& git -C $Repo14 config user.name) "human" "worktree-path input: main stays the account owner's"

Write-Host "15. True failure only when NOTHING resolves (no bot id, no account-owner fallback)"
$Repo15 = MakeRepo "with-origin"
$env:AGENT_GIT_NAME = "definitely-not-a-real-bot-xyz[bot]"
Remove-Item env:AGENT_GIT_BOT_ID -ErrorAction SilentlyContinue
Remove-Item env:GIT_USER_NAME -ErrorAction SilentlyContinue
Remove-Item env:GH_TOKEN -ErrorAction SilentlyContinue
$Rc = 0
try { & $Script $Repo15 *> $null } catch { $Rc = $LASTEXITCODE }
if ($Rc -ne 0) { Ok "exits non-zero when nothing resolves" } else { Bad "should exit non-zero when nothing resolves" }
if (-not (Test-Path (Join-Path $Repo15 ".git" "agent-bot-identity.config"))) { Ok "no bot config written when nothing resolves" } else { Bad "bot config written despite no resolvable identity" }

# --preflight tests. We use a fake `gh` on a local PATH to avoid calling the real gh.
function RunPreflight($Repo, $GhBin) {
    $envPath = $env:PATH
    if ($GhBin) { $env:PATH = "$GhBin" + [System.IO.Path]::PathSeparator + $envPath }
    $Rc = 0
    try { & $Script --preflight $Repo *> $null } catch { $Rc = $LASTEXITCODE }
    if ($GhBin) { $env:Path = $envPath }
    return $Rc
}

Write-Host "16. --preflight refuses the main repo (bot identity not in effect)"
$Repo16 = MakeRepo "with-origin"
$env:AGENT_GIT_NAME = "myagent[bot]"
$env:AGENT_GIT_BOT_ID = "320010330"
$env:GH_TOKEN = "dummy"
$Rc = RunPreflight $Repo16 $null
if ($Rc -ne 0) { Ok "preflight exits non-zero in main repo" } else { Bad "exit code wrong" }
$Out16 = & $Script --preflight $Repo16 2>&1
if ($Out16 -match "bot identity not in effect") { Ok "preflight names the bot-identity-not-in-effect cause" } else { Bad "preflight did not name the bot-identity-not-in-effect cause" }

Write-Host "17. --preflight requires GH_TOKEN; passes when bot identity resolves"
$Repo17 = MakeRepo "with-origin"
$WtDir = MakeWorktree $Repo17
$env:AGENT_GIT_NAME = "myagent[bot]"
$env:AGENT_GIT_BOT_ID = "320010330"
# Apply the bot identity to the repo (writes includeIf into the shared .git).
& $Script $Repo17 *> $null
$GhBin = MakeFakeGh "bot"
# 17a: no GH_TOKEN -> fail.
$Rc = RunPreflight $WtDir $GhBin
if ($Rc -ne 0) { Ok "preflight exits non-zero without GH_TOKEN" } else { Bad "exit code wrong" }
# 17b: with GH_TOKEN + bot gh -> pass.
$env:GH_TOKEN = "dummy"
$Rc = RunPreflight $WtDir $GhBin
if ($Rc -eq 0) { Ok "preflight passes in linked worktree with bot identity + bot GH_TOKEN" } else { Bad "preflight should pass in linked worktree with bot identity + bot GH_TOKEN" }

Write-Host "18. --preflight is location-agnostic but effect-strict: a SEPARATE clone still fails"
$Repo18c = MakeRepo "with-origin"
$Clone18 = Join-Path $Sandbox "clone18"
New-Item -ItemType Directory -Path $Clone18 -Force | Out-Null
& git -C $Repo18c clone --quiet "$Repo18c" "$Clone18" 2>$null
$env:AGENT_GIT_NAME = "myagent[bot]"
$env:AGENT_GIT_BOT_ID = "320010330"
$env:GH_TOKEN = "dummy"
$Rc = RunPreflight $Clone18 $null
if ($Rc -ne 0) { Ok "preflight fails closed in a separate clone (effect-based, not path-based)" } else { Bad "preflight must fail in a separate clone" }
Remove-Item $Clone18 -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "19. --preflight verifies the GH_TOKEN actor is the BOT (not the account owner)."
$Repo19 = MakeRepo "with-origin"
$WtDir = MakeWorktree $Repo19
$env:AGENT_GIT_NAME = "myagent[bot]"
$env:AGENT_GIT_BOT_ID = "320010330"
$env:GH_TOKEN = "dummy"
& $Script $Repo19 *> $null
# 19a: bot token (gh api user -> 403) -> preflight passes.
$GhBin = MakeFakeGh "bot"
$Rc = RunPreflight $WtDir $GhBin
if ($Rc -eq 0) { Ok "preflight passes when GH_TOKEN is a bot install token (gh api user 403)" } else { Bad "preflight should pass when GH_TOKEN is a bot install token" }
# 19b: human token (gh api user -> User), no consent -> preflight FAILS.
$GhBin = MakeFakeGh "human" "koalyptus"
Remove-Item env:AGENT_GIT_ALLOW_HUMAN_ACTOR -ErrorAction SilentlyContinue
$Rc = RunPreflight $WtDir $GhBin
if ($Rc -ne 0) { Ok "preflight fails closed when GH_TOKEN actor is the account owner (no consent)" } else { Bad "exit code wrong" }
$Out19b = & $Script --preflight $WtDir 2>&1
if ($Out19b -match "GH_TOKEN is the account owner") { Ok "account-owner-actor failure names the ACCOUNT OWNER consequence" } else { Bad "account-owner-actor failure did not name the ACCOUNT OWNER consequence" }
# 19c: human token, explicit consent -> pass.
$env:AGENT_GIT_ALLOW_HUMAN_ACTOR = "1"
$Rc = RunPreflight $WtDir $GhBin
if ($Rc -eq 0) { Ok "preflight passes as the account owner only with explicit AGENT_GIT_ALLOW_HUMAN_ACTOR=1" } else { Bad "preflight should pass with explicit account-owner-actor consent" }
Remove-Item env:AGENT_GIT_ALLOW_HUMAN_ACTOR -ErrorAction SilentlyContinue
# 19d: gh present but unverifiable -> pass (warns).
$GhBin = MakeFakeGh "bot"
$Rc = RunPreflight $WtDir $GhBin
if ($Rc -eq 0) { Ok "preflight passes (does not block) when gh is present but unverifiable" } else { Bad "preflight must not hard-block when gh present but unverifiable" }
# gh truly absent: build a PATH with no gh binary.
$NoGhBin = Join-Path $Sandbox "noghbin"
New-Item -ItemType Directory -Path $NoGhBin -Force | Out-Null
# Remove gh from PATH by putting only a minimal dir that has git and bash-like tools via pwsh.
$OrigPath = $env:Path
$env:Path = "$NoGhBin" + [System.IO.Path]::PathSeparator + $env:Path
# Create fake git that works via the real git on PATH (no gh in path).
$Rc = RunPreflight $WtDir $null
if ($Rc -eq 0) { Ok "preflight passes (warns) when gh is unavailable" } else { Bad "preflight must not hard-fail when gh is unavailable" }
$env:Path = $OrigPath
Remove-Item env:AGENT_GIT_ALLOW_HUMAN_ACTOR -ErrorAction SilentlyContinue
Remove-Item env:GH_TOKEN -ErrorAction SilentlyContinue
Remove-Item env:AGENT_GIT_ALLOW_TMP -ErrorAction SilentlyContinue

Write-Host "PASS=$Pass FAIL=$Fail"
if ($Fail -ne 0) { exit 1 }
