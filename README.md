# agent-git-setup

Give an AI agent a bot identity in local git worktrees and/or on GitHub to easily distinguish agentic authors on Git and GitHub. 

## Requirements

- **Unix-like shell** (`bash`) and `git`. The script and tests target Linux and
  macOS. **Windows is not supported as-is** — `bash` + `git` under WSL or Git
  Bash will work, but native `cmd`/`PowerShell` will not (the script uses POSIX
  shell features and git worktree paths).
- `shellcheck`/`shfmt` are only needed if you run the
  lint job (they are installed automatically in CI).
- `Python` 3 and `cryptography`

## 1. Gather values

You will fill the `[...]` placeholders in step 2 with these values.

### Git-only (minimal — no GitHub App, you already have a `GH_TOKEN`)

- **`AGENT_GIT_NAME`**: the bot commit author, e.g. `myagent[bot]` (any name works).
- **`GIT_USER_NAME`**: your GitHub handle, e.g. `my-git-user-name`. The agent/skill
  resolves it to the numeric id via the GitHub API — you never run `curl | jq`.
- **`GH_TOKEN`**: must already be exported in the agent's shell (`export GH_TOKEN=ghp_...`).
  Do **not** put the token value in the prompt. How to get one: GitHub → Settings →
  Developer settings → Personal access tokens → generate a PAT or fine-grained token.
- **Optional** `AGENT_GIT_SIGNINGKEY`: `key::<ssh-pubkey>` for a verified `[bot]` badge.

### GitHub App (uses `mint-token.sh` from this repo)

Like Git-only, but the skill mints `GH_TOKEN` with:

```bash
source <(./mint-token.sh --app-id "$GITHUB_APP_ID" --pem "$GITHUB_APP_PEM" --shell)
```

You provide:

- `AGENT_GIT_NAME` — the bot author, e.g. `myagent[bot]`.
- `GIT_USER_NAME` — human GitHub account that owns the token/app, e.g. `my-git-user-name`.
- `GITHUB_APP_ID` — App ID from GitHub App settings.
- `GITHUB_APP_PEM` — path to the `.pem` private key (outside any repo).
- Optional `AGENT_GIT_SIGNINGKEY` as above.

The one-time GitHub App creation (create app → download PEM → install on repos)
is a separate human step; see the full README ("GitHub App setup") for details.

## 2. Paste this prompt to the agent

Replace every `[...]` with the value you gathered, then send the whole block:

```text
[USER PROMPT — replace every [value] below]

Use the agent-git-setup skill. Set up a bot git identity for the repo at
[REPO_PATH] (e.g. ~/dev/my-project).

[Git-only — fill these if you already have a GH_TOKEN and no GitHub App]
AGENT_GIT_NAME=[myagent[bot]]
GIT_USER_NAME=[my-git-user-name]

[OR GitHub App — fill these if using mint-token.sh]
AGENT_GIT_NAME=[myagent[bot]]
GIT_USER_NAME=[my-git-user-name]
GITHUB_APP_ID=[4646191]
GITHUB_APP_PEM=[~/.ssh/myagent.pem]

[Both paths — fill these if you want verified commits, otherwise omit]
AGENT_GIT_SIGNINGKEY=[key::ssh-ed25519 AAAA... bot@github]

After minting and setting env, run:
agent-git-setup.sh [REPO_PATH]

Then do your git work inside the printed worktree. Do not touch the main tree.
```

- `[REPO_PATH]` is an existing local git repository.
- `GH_TOKEN` is **not** a placeholder — it must already be in the agent's
  environment (Git-only: you exported it; GitHub App: skill mints it via
  `mint-token.sh --shell`).
- Delete `[GITHUB_APP_ID]`/`[GITHUB_APP_PEM]` if you use Git-only; omit
  `AGENT_GIT_SIGNINGKEY` if you don't want verified commits.

## 3. What happens

1. `GH_TOKEN` exported (by you, or by `mint-token.sh` for the App path).
2. `GIT_USER_NAME` resolved to numeric id via `GET /users/$GIT_USER_NAME`
   (skill/script does this with `GH_TOKEN`).
3. `agent-git-setup.sh [REPO_PATH]` creates `.worktrees/agent` and writes
   `user.name` / `user.email` scoped to that worktree only.
4. Agent works inside the printed worktree: `commits → <name>[bot]`,
   `gh/API → <name>[bot]`, `git push → your credential` (main tree untouched).

Full details, diagrams, GitHub App setup, and reference tables are below.

## Flow diagram (happy path)

```
┌─────────────────────┐
│      Human          │
│  gives agent prompt │
│  ─────────────────  │
│ "Use agent-git-     │
│  setup skill on     │
│  <repo-path>"       │
└─────────┬───────────┘
          │
          ▼
┌─────────────────────┐
│  Token source       │  (any push-capable GH_TOKEN)
│  ─────────────────  │
│  Option A:          │  mint-token.sh + GitHub App
│    mint-token.sh    │    (create app, download PEM,
│    --app-id --pem   │     install, get bot user ID)
│    --shell          │
│  Option B:          │  Other backend (harness, PAT, etc.)
│    your token minter│
└─────────┬───────────┘
          │ exports GH_TOKEN
          ▼
┌─────────────────────┐
│  env: AGENT_GIT_*   │  (set by agent/skill)
│  ─────────────────  │
│  AGENT_GIT_NAME     │  e.g. myagent[bot]
│  GIT_USER_NAME  │  handle (agent resolves to id)
│  AGENT_GIT_SIGNINGKEY│ (optional, for verified)
└─────────┬───────────┘
          │
          ▼
┌─────────────────────┐
│ agent-git-setup.sh  │
│  ─────────────────  │
│  git worktree add   │  → .worktrees/agent/
│  write worktree     │     .git/worktrees/agent/config
│    user.name        │     user.name = <name>[bot]
│    user.email       │     user.email = <id>+<name>[bot]@...
│    signingkey       │     (main tree untouched)
└─────────┬───────────┘
          │
          ▼
┌─────────────────────┐
│   Agent works in    │
│   the worktree      │
│  ─────────────────  │
│  commits → <name>[bot]     │
│  gh/API   → <name>[bot] (GH_TOKEN)
│  git push → your credential│
└─────────────────────┘
```

## What it does

An AI coding agent should be able to **commit as a distinct bot identity**,
without that identity leaking into your own working tree. `agent-git-setup.sh`
creates an isolated **git worktree** and configures it so that commits authored
there are attributed to a bot, while your main checkout stays exactly as you.

The bot identity is the **commit author** (the `user.name`/`user.email` stamped
on each commit). It does **not** change who pushes: a plain `git push` from the
worktree uses your normal credential, so the push actor stays you. GitHub-side
operations driven by `GH_TOKEN` in the agent's environment (PRs, issues,
comments via `gh`/API) are the bot. See "Commit-author isolation" below.

It handles two distinct things:

1. **Local worktree commit identity (required).** Inside the worktree only,
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

- **Not backend-specific.** Works the same under any agent or harness.
- **Not token-agnostic by accident — by design.** It does **not** mint tokens and
  contains no secrets. It expects `GH_TOKEN` to already be present in the
  environment (minted by whatever backend/agent you use) and only *consumes* it.
- **Not coupled to any worktree tool.** If `treehouse` is installed it is used to
  obtain the worktree; otherwise a plain `git worktree add` is used. Same result.
- **Not touching your main tree.** All configuration is scoped to the worktree.
  Your main repository and global git config are never modified.

## Commit-author isolation (by design)

`agent-git-setup.sh` isolates the **commit author** in the worktree, not the
**push credential**. This is a deliberate, safe choice:

- A git worktree *shares* its main repo's remotes and most config. Rewriting
  `origin` to inject a token would change your main tree too — exactly what we
  avoid. So the script writes `user.name` / `user.email` to the worktree's own
  config file and leaves `origin` alone.
- **Result:** commits authored in the worktree show as `<name>[bot]`. Plain
  `git push` uses the repo's normal credential (the push actor is you, unless
  your push mechanism also uses `GH_TOKEN`). `gh`/API calls (PRs, issues,
  comments) made with `GH_TOKEN` in the agent's environment are the bot.

If you later want the *push* to be the bot too, do it outside this script (e.g.
a separate remote or credential helper scoped to the worktree) — but the
default stays safe: your main tree is never touched.

## GitHub App setup (one-time, per bot identity)

`agent-git-setup.sh` consumes a token but does not create one. The cleanest
source of a bot token is a **GitHub App** installed on your account. This is a
one-time, manual step (it needs the GitHub web UI + your login); everything
afterwards is reproducible.

### 1. Create the app

Go to **GitHub → Settings → Developer settings → GitHub Apps → New GitHub App**.
For an automation-only private app, set ONLY:

- **GitHub App name**: e.g. `myagent` (this becomes `myagent[bot]`).
- **Homepage URL**: required on the form — any URL works (e.g. your profile).
- **Where can this be installed?**: *Only on this account* (keeps it private).
- **Repository permissions**:
  - Contents → Read & write (commits + pushes)
  - Pull requests → Read & write (if the agent opens/merges PRs)
  - Metadata → Read (always required)
- Leave unchecked / blank: Redirect URI, webhook (Active **off**), events,
  OAuth, Device Flow, and all user/org/account permissions.

After creating: note the **App ID** (shown on the app page).

### 2. Generate the private key

On the app page, **Generate a private key (PEM)** and download the `.pem` file.
Keep it secret — it is what mints tokens. Store it outside any git repo
(e.g. `~/.ssh/myagent.pem`).

### 3. Install the app on your repos

On the app page, click **Install** and select the repositories the agent should
touch. Installation grants permission; it does NOT change the bot name.

### 4. Get the bot handle

The commit email needs the **bot user id**, which the skill resolves from
`GIT_USER_NAME`. For `GIT_USER_NAME` use your GitHub username (e.g. `my-git-user-name`)
— distinct from `AGENT_GIT_NAME` (`myagent[bot]`, the commit author). The script
fetches the numeric id via the API at setup time using `GH_TOKEN`
(`GET /users/<GIT_USER_NAME>`). No `curl | jq .id` needed from you.

### 5. Mint tokens with `mint-token.sh` (required for the happy path)

This repo ships the minter — `mint-token.sh` — because token minting is the
core of the setup, not an afterthought. It mints a GitHub App installation
token (RS256 JWT, needs only `python3` + `cryptography`):

```bash
source <(./mint-token.sh --app-id "$APP_ID" --pem "$PEM_PATH" --shell)
# GH_TOKEN is now exported in your shell
```

Set the env vars (`GITHUB_APP_ID`, `GITHUB_APP_PEM`) or pass `--app-id` /
`--pem`. The token is short-lived (~1h); re-run for a fresh one.

`agent-git-setup.sh` only *consumes* `GH_TOKEN` and stays token-agnostic — any
other source works too — but `mint-token.sh` is the provided, primary minter
and the one the agent uses in the happy path.

### 6. Optional: verified `[bot]` signing

To get the green **Verified** badge on commits, enable commit signing on the
app and upload its SSH signing key, then pass it as `AGENT_GIT_SIGNINGKEY`
(`key::<pubkey>`). Without this, commits still show as `myagent[bot]` but
unverified.

## Install

```bash
git clone https://github.com/koalyptus/agent-git-setup
# put the script on PATH (or call it by absolute path):
ln -s "$PWD/agent-git-setup.sh" ~/.local/bin/agent-git-setup.sh
# or just:  cp agent-git-setup.sh ~/.local/bin/
```

A skill definition (`skills/SKILL.md`) ships in the repo so agents that load
skills from a repo can pick it up directly.

## Tests

The suite is hermetic (temp repos, sandboxed `HOME`/`GIT_CONFIG_GLOBAL`, dummy
token, no network, auto-cleanup) and needs only `bash` + `git`:

```bash
bash agent-git-setup-test.sh
```

It prints each check (`ok` / `FAIL`) and exits non-zero if any fail. The same
suite runs automatically in CI (`.github/workflows/test.yml`) on every push and
pull request, so a regression shows up as a red check before merge.

## Make targets

A `Makefile` wraps the local checks so you don't have to remember the exact
commands:

| Command        | What it does                                                                          |
|----------------|---------------------------------------------------------------------------------------|
| `make test`    | Run the hermetic test suite (`agent-git-setup-test.sh`).                              |
| `make lint`    | Run `shellcheck` + `shfmt -d` on both scripts (needs those tools).                    |
| `make install` | Install `shellcheck` + `shfmt` + `python3`/`cryptography` if missing (idempotent).   |
| `make ci`      | Run `test` + `lint` — exactly what CI runs. Use this before push.                     |

`make ci` is the pre-push gate: only push when it exits green. The CI workflow
mirrors it, and `main` is branch-protected so `test` + `lint` must be green to
merge.

## Usage

```bash
agent-git-setup.sh <repo-dir> [worktree-name] [branch]
```

### Required environment

| Variable             | Meaning                                                              |
|----------------------|----------------------------------------------------------------------|
| `GH_TOKEN`           | A push-capable GitHub token (e.g. a GitHub App install token).       |
| `AGENT_GIT_NAME`     | Commit author name, e.g. `myagent[bot]`.                            |
| `GIT_USER_NAME` | GitHub handle (e.g. `my-git-user-name`) — the agent/script resolves it to the numeric id via the GitHub API (needs `GH_TOKEN`). |
| `GIT_USER_ID`        | *(hidden fallback)* Numeric id, alternative to `GIT_USER_NAME`. Only for hermetic tests / offline use; never in the prompt. |

The commit author (`user.name` / `user.email`) is set from the required
variables above — it is **not** optional.

### Optional: verified commit signing

| Variable              | Meaning                                                              |
|----------------------|----------------------------------------------------------------------|
| `AGENT_GIT_SIGNINGKEY` | An SSH public key (`key::<pubkey>`) for a **verified** `[bot]` badge. |

Without this, commits still show as `<name>[bot]` but **unverified**. With it,
they get the green Verified checkmark. Requires the GitHub App to have commit
signing enabled and its SSH key uploaded.

### Defaults (override via environment or arguments)

| Variable              | Default     | Meaning                                  |
|----------------------|-------------|------------------------------------------|
| `AGENT_GIT_WORKTREE` | `agent`     | Worktree directory name.                |
| `AGENT_GIT_BRANCH`   | `agent-work`| Branch created in the worktree.          |

### Example

```bash
export GH_TOKEN="$(mint-my-token)"            # backend-specific; not this script's job
export AGENT_GIT_NAME="myagent[bot]"
export GIT_USER_NAME="my-git-user-name"           # handle; script/skill resolves to numeric id
export AGENT_GIT_SIGNINGKEY="key::ssh-ed25519 AAAA... bot@github"  # optional

agent-git-setup.sh ~/dev/my-repo
# -> worktree at ~/dev/my-repo/.worktrees/agent
#    commits there: myagent[bot] <id+myagent[bot]@users.noreply.github.com>
#    your ~/dev/my-repo main tree: untouched
```

Re-running is **idempotent**: an existing worktree is reconfigured, not recreated.

## Why a worktree

A worktree gives the agent its own checkout and its own `user.*` config, so the
bot identity applies *only* there. Your manual commits in the main tree remain
yours — no `git config` discipline required, no collision.

## Backend notes (how the token gets there)

`agent-git-setup.sh` only consumes `GH_TOKEN`. How it arrives is the backend's
job — any mechanism that places a push-capable token in the agent's environment
works (for example, a GitHub App install token minted at agent launch, or a
fine-grained token provisioned by the harness). The script is agnostic to all
of the above.

## License

MIT.

