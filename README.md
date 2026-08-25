# agent-git-setup

Give an AI agent a bot identity so its git commits and GitHub actions are clearly attributed to the agent, distinct from the human's account. The agent works in a worktree its harness already created; this repo only scopes the bot commit identity to that worktree.

## Requirements

- **Requires git >= 2.43** on the agent's machine: it needs `extensions.worktreeConfig` for per-worktree isolation. The harness that creates the worktree is expected to have enabled this extension in the main repo (one-time, `git config extensions.worktreeConfig true`). If it is missing, the script errors and tells the agent to **ask the human** whether they may enable it — it never enables it silently.
- **Unix-like shell** (`bash`) and `git`. The script and tests target Linux and
  macOS. **Windows is not supported as-is** — `bash` + `git` under WSL or Git
  Bash will work, but native `cmd`/`PowerShell` will not (the script uses POSIX
  shell features).
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

Do the one-time App setup first, then give the agent the values below.

**One-time App setup**

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

Pick **one** of these — whichever matches your setup. Replace every `[...]` then send the whole block (no line-deleting, no `REPO_PATH` — agent infers the current repo):

#### Git-only

Use the prompt below with replaced values prepared in step 2.

```text
Use the agent-git-setup skill. Set up a bot git identity for current repo.

AGENT_GIT_NAME=[myagent[bot]]
GIT_USER_NAME=[my-git-user-name]

After setting the env vars above, run `scripts/agent-git-setup.sh <worktree-dir>` where
`<worktree-dir>` is the worktree your harness already created for the agent.

Then do your git work inside that worktree. Do not touch the main tree.
```

#### GitHub App

Use the prompt below with replaced values prepared in step 2.

```text
Use the agent-git-setup skill. Set up a bot git identity for current repo.

AGENT_GIT_NAME=[myagent[bot]]
GIT_USER_NAME=[my-git-user-name]
GITHUB_APP_ID=[4646191]
GITHUB_APP_PEM=[/path/to/myagent.pem]

After setting the env vars above (mint the token first if using the GitHub App), run `scripts/agent-git-setup.sh <worktree-dir>` where `<worktree-dir>` is the worktree your harness already created for the agent.

Then do your git work inside that worktree. Do not touch the main tree.
```

## 4. What happens

1. The agent authenticates itself if needed. If it has to use GitHub (open PRs, comment on issues), it creates its own short-lived token — you don't provide one. If it only makes local commits, no token is needed at all.

2. The agent resolves the bot's numeric id via the public GitHub API (`GET /users/<bot>`).

3. The agent runs `scripts/agent-git-setup.sh <worktree-dir>` inside the worktree its harness already created. The script writes the bot identity into that worktree's OWN config file (scoped to the worktree, never the main repo) and prints `isolation verified — main tree untouched` on success; if it prints `ERROR`, the worktreeConfig extension is missing — ask the human to enable it and re-run.

4. The agent does all its work inside that worktree. Commits appear as {agent-name}[bot] in the commit list (no badge by default). GitHub actions appear as {agent-name}[bot] (when a token was needed), and git push still uses your account. Your main checkout is never changed.

Full details, diagrams, and reference tables are below (GitHub App setup is already in §2 above).

## Flow diagram (happy path)

```
┌──────────────────────────────────────┐
│              Human                    │
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
│   writes worktree's OWN config        │  .git/worktrees/<name>/config.worktree
│     user.name = <name>[bot]           │     user.email = <bot_id>+<name>[bot]@...
│     user.email = (bot noreply)        │  (harness already created the worktree
│                                        │   + enabled extensions.worktreeConfig
│                                        │   in the main repo)
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
worktree uses your normal credential, so the push actor stays you. GitHub-side
operations driven by `GH_TOKEN` in the agent's environment (PRs, issues,
comments via `gh`/API) are the bot. See "Commit-author isolation" below.

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

- **Not backend-specific.** Works the same under any agent or harness.
- **Not token-agnostic by accident — by design.** It does **not** mint tokens and
  contains no secrets. It expects `GH_TOKEN` to already be present in the
  environment (minted by whatever backend/agent you use) and only *consumes* it.
- **Not a worktree manager.** The harness owns worktree creation, branching,
  hooks, and `core.hooksPath`. This script only writes identity into the
  worktree the harness already made — it never creates a worktree, installs
  hooks, or imposes a path/branch convention.
- **Not touching your main tree.** All configuration is scoped to the worktree.
  Your main repository and global git config are never modified (the script
  only reads `extensions.worktreeConfig`; it does not enable it).

## Commit-author isolation (by design)

`scripts/agent-git-setup.sh` isolates the **commit author** in the worktree, not the
**push credential**. This is a deliberate, safe choice:

- The script relies on the git `worktreeConfig` extension (`extensions.worktreeConfig=true` in the main repo config). On git 2.43+ this is **required** for the per-worktree config file at `.git/worktrees/<name>/config.worktree` to be read at all; without it the bot identity would leak into the shared main config. The harness that created the worktree is expected to have enabled it. The script reads it and **errors loudly** (telling the agent to *ask the human* to enable it) if it is missing — it never enables the extension itself, because that writes to your main repo. After writing the identity it prints an isolation check (`worktree user.name` = bot, `main tree user.name` = human) that fails loudly if the worktree config is not being read.
- Rewriting `origin` to inject a token would change your main tree too — exactly what we avoid. The script does **not** set `remote.origin.url` in the worktree config; it only sets `user.name`/`user.email`. The bot actor for `gh`/API (PRs, issues, comments) is provided by `GH_TOKEN` in the agent's environment — **not** by rewriting `origin`. Plain `git push` uses the repo's normal credential (the push actor is you, unless your push mechanism also uses `GH_TOKEN`). The agent must not rewrite `origin` either (see the skill).
- **Result:** commits authored in the worktree show as `<name>[bot]` in the commit list. Plain `git push` uses the repo's normal credential. `gh`/API calls (PRs, issues, comments) made with `GH_TOKEN` in the agent's environment are the bot.

If you later want the *push* to be the bot too, do it outside this script (e.g.
a separate remote or credential helper scoped to the worktree) — but the
default stays safe: your main tree is never touched.

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

| Command                   | What it does                                                                          |
|---------------------------|---------------------------------------------------------------------------------------|
| `make test`               | Run the hermetic test suite (`agent-git-setup-test.sh`).                              |
| `make lint`               | Run `shellcheck` + `shfmt -d` on both scripts (needs those tools).                    |
| `make install`            | Install `shellcheck` + `shfmt` + `python3`/`cryptography` if missing (idempotent).   |
| `make sync-skill-scripts` | Copy `scripts/*.sh` into `skills/agent-git-setup/scripts/` (skill bundle). Run when you change a script at the repo root. |
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
scripts/agent-git-setup.sh <repo-dir> [worktree-name] [branch]
```

### Required environment

| Variable             | Meaning                                                              |
|----------------------|----------------------------------------------------------------------|
| `AGENT_GIT_NAME`     | Commit author name, e.g. `myagent[bot]`.                            |
| `GIT_USER_NAME`      | GitHub handle (e.g. `my-git-user-name`) — resolved via the public GitHub API (`GET /users/<handle>` — no `GH_TOKEN` needed). |
| `GH_TOKEN`           | *(Optional)* A push-capable GitHub token (e.g. a GitHub App install token) — only for `gh`/API as the bot. Not needed for the local commit author.       |
| `GIT_USER_ID`        | *(hidden fallback)* Numeric id, alternative to `GIT_USER_NAME`. Only for hermetic tests / offline use; never in the prompt. |

The commit author (`user.name` / `user.email`) is set from the required
variables above — it is **not** optional.

### Example

```bash
export GH_TOKEN="$(mint-my-token)"            # backend-specific; not this script's job
export AGENT_GIT_NAME="myagent[bot]"
export GIT_USER_NAME="my-git-user-name"           # handle; script/skill resolves to numeric id

scripts/agent-git-setup.sh ~/dev/my-repo/.worktrees/agent   # the worktree the harness created
# -> worktree user.name/user.email set to myagent[bot] <bot_id+myagent[bot]@users.noreply.github.com>
#    commits there: myagent[bot] (agent name shows in commit list)
#    your ~/dev/my-repo main tree: untouched
```

Re-running is **idempotent**: the worktree identity is reconfigured, not recreated.

## Why a worktree

A worktree gives the agent its own checkout and its own `user.*` config, so the
bot identity applies *only* there. Your manual commits in the main tree remain
yours — no `git config` discipline required, no collision.

## Backend notes (how the token gets there)

`scripts/agent-git-setup.sh` only consumes `GH_TOKEN`. How it arrives is the backend's
job — any mechanism that places a push-capable token in the agent's environment
works (for example, a GitHub App install token minted at agent launch, or a
fine-grained token provisioned by the harness). The script is agnostic to all
of the above.

## License

MIT.