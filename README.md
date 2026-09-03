# agent-git-setup

Give an AI agent a bot identity so its git commits and GitHub actions are clearly attributed to the agent, distinct from your account. The agent works in a worktree its harness already created; this repo only scopes the bot commit identity to that worktree.

## Requirements

- **git >= 2.43** and **PowerShell 7+** on the agent's machine.
  `scripts/agent-git-setup.sh` targets Linux/macOS (`bash` + `git`).
  `scripts/agent-git-setup.ps1` provides native Windows support
  (`cmd`/`PowerShell`). The test suite runs on both platforms
  (`tests/agent-git-setup-test.sh` on Linux/macOS,
  `tests/agent-git-setup-test.ps1` on Windows).
  `includeIf` conditional-include scopes the bot identity to all
  worktrees of the repo (including ones created later) while keeping
  your main repo untouched — no `worktreeConfig` extension or harness
  setup required.
- **`gh` (GitHub CLI) is required for the bot GitHub-actor path** (PRs, comments, API commits). Plain local commits need only `git`.
- `Make install` installs `shellcheck`/`shfmt`, `Python 3` and `cryptography` if needed.

## Install

Clone the repository:

```
git clone https://github.com/koalyptus/agent-git-setup
```

### 1. Install the skill in your harness

Consult that harness's docs for the exact install / "load skill from repo" command. Alternatively, copy `skills/agent-git-setup/SKILL.md` into the harness's skills folder (the standard `<skills>/<skill-name>/SKILL.md` layout this repo uses), or point the harness at the raw URL below:

```
https://raw.githubusercontent.com/koalyptus/agent-git-setup/main/skills/agent-git-setup/SKILL.md
```

### 2. Prepare relevant Git information

You will fill the `[...]` placeholders in step 3 with these values.

#### Git-only

**`AGENT_GIT_NAME`**: the bot commit author, e.g. `myagent[bot]` (any name works).

**`GIT_USER_NAME`**: your GitHub handle, e.g. `my-git-user-name`.

#### GitHub App

You need a GitHub App (with its PEM) and its App ID. If you already have one,
skip to the values below. To create one, see the steps under "Creating a GitHub
App".

**Creating a GitHub App** (one-time, if not already done)

1. **Create the app** — GitHub → **Settings → Developer settings → GitHub Apps → New GitHub App**. For a private automation-only app set only:
   - **GitHub App name**: e.g. `myagent` (this becomes `myagent[bot]` on GitHub), matches `AGENT_GIT_NAME` without the `[bot]` part.
   - **Homepage URL**: required on the form — any URL works (e.g. your profile).
   - **Webhook**: Active **off**
   - **Repository permissions**:
      - Contents → Read & write (commits/pushes)
      - Pull requests → Read & write (if the agent opens PRs)
      - Metadata → Read (always required).
   - **Where can this be installed?**: *Only on this account* (keeps it private).
   - Leave blank/unchecked:
      - Redirect URI
      - events
      - OAuth
      - Device Flow
      - and all user/org permissions.
   - After creating, note the **App ID** shown on the app page.
2. **Generate the private key** — on the app page click **Generate a private key (PEM)**, download the `.pem`, keep it secret and store it **outside any git repo** (e.g. `~/.ssh/myagent.pem`).
3. **Install the app** — on the app page click **Install** and select the repositories the agent should touch. This grants permission; it does not change the bot name.

**Information you then give the agent (fill the `[...]` in §3):**

- `AGENT_GIT_NAME` — the bot author, e.g. `myagent[bot]` (matches the App name).
- `GIT_USER_NAME` — your GitHub handle, e.g. `my-git-user-name`.
- `GITHUB_APP_ID` — the App ID from step 1.
- `GITHUB_APP_PEM` — path to the `.pem` from step 2 (e.g. `~/.ssh/myagent.pem`).

### 3. Paste this prompt to the agent

Pick **one** of these — whichever matches your setup. Replace every `[...]` then send the whole block (no line-deleting). `<repo-dir>` is the repo (or a worktree of it) you want the agent to work in; the agent can also infer the current repo:

#### Git-only

Fill in the `[...]` and paste the prompt below to the agent.

```text
Use the agent-git-setup skill. Set up a bot git identity for current repo.

AGENT_GIT_NAME=[myagent[bot]]
GIT_USER_NAME=[my-git-user-name]
```

#### GitHub App

Fill in the `[...]` and paste the prompt below to the agent.

```text
Use the agent-git-setup skill. Set up a bot git identity for current repo.

AGENT_GIT_NAME=[myagent[bot]]
GIT_USER_NAME=[my-git-user-name]
GITHUB_APP_ID=[4646191]
GITHUB_APP_PEM=[/path/to/myagent.pem]
```

Note: the agent writes the one-time credentials file itself from the `GITHUB_APP_ID` / `GITHUB_APP_PEM` values in your prompt. For multiple bot identities (one per repo), the agent writes `credentials.d/credentials-<APP_ID>.env` (keyed by the numeric App ID from your prompt) and `mint-token.sh` auto-selects it — no name→app-id mapping needed. The file holds only the public App ID + the **path** to the PEM you already downloaded, never the PEM bytes or a live token. From then on the skill mints `GH_TOKEN` from that file automatically, so you do **not** pass a token per session.

## 4. What happens

See `skills/agent-git-setup/SKILL.md` for the step-by-step the agent follows (resolve bot id → write identity → work in worktree). Summary: commits land as `<name>[bot]`; your main repo is untouched; GitHub actions need a per-session `GH_TOKEN` the agent mints from the credentials file.

Full details, diagrams, and reference tables are below.

## Flow diagram (happy path)

```
┌──────────────────────────────────────┐
│              You                     │
│   gives agent prompt                  │
│   ────────────────────────────────   │
│   "Use agent-git-setup skill on      │
│    <repo-path>"                      │
└──────────────┬───────────────────────┘
               │
               ▼
┌──────────────────────────────────────┐
│           Token source                │  (only if you need gh/API as the bot)
│   ────────────────────────────────   │
│   Option A:                           │  scripts/mint-token.sh + GitHub App
│     scripts/mint-token.sh             │    (create app, download PEM,
│     --app-id --pem                    │     install, get bot user ID)
│     --shell                           │
│   Option B:                           │  Other backend (harness, PAT, etc.)
│     your token minter                 │
└──────────────┬───────────────────────┘
               │ exports GH_TOKEN
               ▼
┌──────────────────────────────────────┐
│        env: AGENT_GIT_*               │  (set by agent/skill)
│   ────────────────────────────────   │
│   AGENT_GIT_NAME                      │  e.g. myagent[bot]
│   GIT_USER_NAME                       │  handle (agent resolves to id)
└──────────────┬───────────────────────┘
               │
               ▼
┌──────────────────────────────────────┐
│   scripts/agent-git-setup.sh          │
│   ────────────────────────────────   │
│   writes ONE bot-identity config      │  .git/agent-bot-identity.config
│     in .git/, included for ALL        │  + includeIf "gitdir/i:**/.git/
│     worktrees via includeIf           │    worktrees/**" in .git/config
│     user.name = <name>[bot]           │     (main repo .git is excluded
│     user.email = (bot noreply)        │      by the glob → stays yours)
└──────────────┬───────────────────────┘
               │
               ▼
┌──────────────────────────────────────┐
│        Agent works in the worktree     │
│   ────────────────────────────────   │
│   commits → <name>[bot] (no badge)    │
│   gh/API   → <name>[bot] (GH_TOKEN)  │
│   git push → your credential          │
└──────────────────────────────────────┘
```

## What it does

An AI coding agent should be able to **commit as a distinct bot identity**,
without that identity leaking into your own working tree. `scripts/agent-git-setup.sh`
writes the bot identity into the **worktree's own config** (the harness creates
the worktree; the script only scopes identity to it), so commits authored there
are attributed to a bot, while your main checkout stays exactly as you.

The bot identity is the **commit author** (the `user.name`/`user.email` stamped
on each commit). It does **not** change who pushes: a plain `git push` from the
worktree uses your normal credential, but the **PR/API actor is the bot** — the
agent opens PRs and acts on GitHub as the bot via `gh` + `GH_TOKEN` in its
environment (PRs, issues, comments via `gh`/API are the bot). See
"Commit-author isolation" below.

It handles two distinct things:

1. **Worktree commit identity (required).** Inside the worktree only,
   `user.name` and `user.email` are set to the bot identity. Commits authored
   there read as the bot. This is pure local git config — no token required.
2. **GitHub actor (PRs / API).** Operations driven by `GH_TOKEN` in the
   agent's environment (`gh`/API calls: PRs, issues, comments) act as the bot.
   Plain `git push` from the worktree uses the repository's normal credential —
   by design the script does **not** rewrite `origin` (git worktrees share
   remotes, so doing so would change your main tree). The local commit *author*
   is the bot; the push *actor* is you. This is the deliberate, safe trade-off
   (see "Commit-author isolation" below).

## What it is not

- **Commit identity is harness-agnostic; the API actor needs the skill.** The bot commit author is plain git config in `.git/`, so it works under any agent or harness with no extra setup. Acting as the bot on GitHub (`GH_TOKEN`) needs the skill installed in that harness, because the mint step lives there — a harness without the skill still commits as the bot but posts to GitHub as you (unless you run `source <(./scripts/mint-token.sh --shell)` yourself).
- **Token-agnostic in consumption, with a provided minter.** The scripts only *consume* `GH_TOKEN` (for `gh`/API as the bot); they never assume a specific backend. This repo also ships `scripts/mint-token.sh`, which mints `GH_TOKEN` from a GitHub App (RS256 JWT, `python3` + `cryptography`) using the persisted credentials file — so the agent provides its own token without you passing one per session. The credentials file holds only the public App ID + the **path** to the PEM; no token is ever stored on disk.
|- **Not a worktree manager.** The harness owns worktree creation, branching,
  hooks, and `core.hooksPath`. This script only writes bot identity into the
  shared repo config (scoped to all worktrees via `includeIf`) — it never creates
  a worktree, installs hooks, or imposes a path/branch convention. Both
  `scripts/agent-git-setup.sh` (bash) and `scripts/agent-git-setup.ps1`
  (PowerShell) behave identically here.
|- **Not touching your main tree.** The bot identity is written to `.git/agent-bot-identity.config` and conditionally included for worktrees only. Your main repo's `.git` directory is excluded by the glob, so it stays yours; global git config is never modified.

## Commit-author isolation (by design)

`scripts/agent-git-setup.sh` isolates the **commit author** in all worktrees, not the
**push credential**. This is a deliberate, safe choice:

- The script writes `user.name`/`user.email` to `.git/agent-bot-identity.config` and adds a conditional include (`includeIf "gitdir/i:**/.git/worktrees/**"`) to the shared `.git/config`. On git 2.43+ this scopes the bot identity to every linked worktree — including ones created after the script runs — while the main repo's own `.git` directory is excluded by the glob, so it stays yours. No `worktreeConfig` extension and no harness setup required. After writing, the script prints `isolation verified — main tree untouched, all worktrees bot`.
- Rewriting `origin` to inject a token would change your main tree too — exactly what we avoid. The script does **not** set `remote.origin.url` in the repo config; it only sets `user.name`/`user.email` (via the included file). The bot actor for `gh`/API (PRs, issues, comments) is provided by `GH_TOKEN` in the agent's environment — **not** by rewriting `origin`. Plain `git push` uses the repo's normal credential (a raw push falls back to your credential, unless your push mechanism also uses `GH_TOKEN`) — but the agent opens PRs **as the bot** via `gh` + `GH_TOKEN`. The agent must not rewrite `origin` either (see the skill).
- **Result:** commits authored in any worktree show as `<name>[bot]` in the commit list. Plain `git push` uses the repo's normal credential. `gh`/API calls (PRs, issues, comments) made with `GH_TOKEN` in the agent's environment are the bot.

If you later want the *push* to be the bot too, do it outside this script (e.g.
a separate remote or credential helper scoped to the worktree) — but the
default stays safe: your main tree is never touched.

## Tests

The suite is hermetic (temp repos, sandboxed `HOME`/`GIT_CONFIG_GLOBAL`,
dummy token, no network, auto-cleanup). Linux/macOS uses `bash` + `git`;
Windows uses PowerShell 7 + `git`:

```bash
bash tests/agent-git-setup-test.sh
pwsh tests/agent-git-setup-test.ps1
```

Both suites print each check (`ok` / `FAIL`) and exit non-zero if any
fail. The same suites run automatically in CI (`.github/workflows/ci.yml`)
on every push and pull request.

## Make targets

A `Makefile` wraps the local checks so you don't have to remember the exact
commands:

| Command                   | What it does                                                                          |
|---------------------------|---------------------------------------------------------------------------------------|
| `make test`               | Run the hermetic test suite (`agent-git-setup-test.sh`).                     |
| `make lint`               | Run `shellcheck` + `shfmt -d` on bash scripts, `pwsh` + `PSScriptAnalyzer`
|                           |   on `*.ps1` (needs those tools).                                 |
| `make install`            | Install `shellcheck` + `shfmt` + `python3`/`cryptography` + PowerShell 7
|                           |   if missing (idempotent).                                        |
| `make sync-skill-scripts` | Copy `scripts/*.sh` and `scripts/*.ps1` into `skills/agent-git-setup/scripts/`
|                           |   (skill bundle). Run when you change a script at the repo root.  |
| `make sync-check`         | Verify the skill bundle matches `scripts/`. Fails if they have drifted.              |
| `make ci`                 | Run `sync-check` + `test` + `lint` — exactly what CI runs. Use this before push.    |

### Skill bundle (why scripts are copied into the skill directory)

Skill-install harnesses resolve any `scripts/...` references inside SKILL.md as
required bundle support files and try to fetch them from inside the skill
directory. So the two scripts must ship **inside** the skill directory, not
just at the repo root. The repo root (`scripts/agent-git-setup.sh`,
`scripts/mint-token.sh`) is the source of truth;
`skills/agent-git-setup/scripts/*.sh` is a bundled copy the harness fetches.

`make ci` runs `sync-check` first and refuses to test/lint a drifted bundle.
When you edit a root script, run `make sync-skill-scripts` and commit the
bundle copy in the same commit as the source change.

`make ci` is the pre-push gate: only push when it exits green. The CI workflow
mirrors it, and `main` is branch-protected so `test` + `lint` must be green to
merge.

## Usage

```bash
scripts/agent-git-setup.ps1 <repo-dir>   # Windows (PowerShell)
scripts/agent-git-setup.sh <repo-dir>    # Linux/macOS (bash)
# -> .git/agent-bot-identity.config set to myagent[bot] <bot_id+myagent[bot]@users.noreply.github.com>,
#    included for every worktree via includeIf
#    commits in any worktree: myagent[bot] (agent name shows in commit list)
#    your <repo-dir> main tree: untouched (excluded by the glob)
```

Re-running is **idempotent**: the bot identity is reconfigured, not recreated.

### PowerShell environment (Windows)

| Variable             | Meaning                                                              |
|----------------------|----------------------------------------------------------------------|
| `AGENT_GIT_NAME`     | Commit author name, e.g. `myagent[bot]`. Preferred identity source. |
| `GIT_USER_NAME`      | GitHub handle (e.g. `my-git-user-name`). LAST-RESORT fallback only. |
| `GH_TOKEN`           | *(Optional)* A GitHub token for `gh`/API as the bot. Same semantics
|                       |   as the bash flow.                                                    |
| `AGENT_GIT_BOT_ID`   | *(hidden fallback)* Numeric id for the bot noreply email. Offline-safe.|
| `AGENT_GIT_ALLOW_TMP`| *(hidden)* Opt-in to allow running from an ephemeral location.        |

The commit author (`user.name` / `user.email`) is set from the required
variables above — it is **not** optional.

### Example

```bash
# Linux/macOS (bash)
export GH_TOKEN="$(scripts/mint-token.sh --print-jwt)"   # this repo's GitHub App minter (uses the persisted credentials file)
export AGENT_GIT_NAME="myagent[bot]"
export GIT_USER_NAME="my-git-user-name"           # handle; script/skill resolves to numeric id
scripts/agent-git-setup.sh ~/dev/my-repo   # the repo (or any worktree of it)

# Windows (PowerShell)
$env:GH_TOKEN = (scripts/mint-token.sh --print-jwt)   # this repo's GitHub App minter
$env:AGENT_GIT_NAME = "myagent[bot]"
$env:GIT_USER_NAME = "my-git-user-name"
scripts/agent-git-setup.ps1 ~/dev/my-repo   # the repo (or any worktree of it)
# -> .git/agent-bot-identity.config set to myagent[bot] <bot_id+myagent[bot]@users.noreply.github.com>,
#    included for every worktree via includeIf
#    commits in any worktree: myagent[bot] (agent name shows in commit list)
#    your ~/dev/my-repo main tree: untouched (excluded by the glob)
```

Re-running is **idempotent**: the bot identity is reconfigured, not recreated.

## Why a worktree

A worktree gives the agent its own checkout and its own `user.*` config, so the
bot identity applies *only* there. Your manual commits in the main tree remain
yours — no `git config` discipline required, no collision.

## Backend notes (how the token gets there)

`scripts/agent-git-setup.sh` only consumes `GH_TOKEN`. This repo also ships `scripts/mint-token.sh`, the expected minter: it produces `GH_TOKEN` from a GitHub App (using the persisted credentials file) and is what the agent uses in the happy path (`source <(./scripts/mint-token.sh --shell)>`). Other mechanisms work too — any way of placing a token in the agent's environment is fine (for example a fine-grained token provisioned by the harness). The script is agnostic to how `GH_TOKEN` arrives; `mint-token.sh` is simply the bundled default.

## License

MIT.