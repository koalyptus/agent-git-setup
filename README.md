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

## 1. Install the skill in your harness

Pick one of these — whichever harness your agent runs in. This is a one-time
human step so the prompt in §3 ("Use the `agent-git-setup` skill…") resolves.

- **Hermes:**
  ```bash
  hermes skills install https://raw.githubusercontent.com/koalyptus/agent-git-setup/main/skills/agent-git-setup/SKILL.md
  # or clone and point at the local copy:
  # hermes skills install ./skills/agent-git-setup --category agent --name agent-git-setup
  ```
- **Other harnesses (Claude Code, OpenCode, Codex, etc.):** copy
  `skills/agent-git-setup/SKILL.md` into the harness's skills folder
  (the standard `<skills>/<skill-name>/SKILL.md` layout this repo uses), or
  point the harness at the raw URL above. Consult that harness's docs for the
  exact install / "load skill from repo" command.

## 2. Prepare relevant Git information

You will fill the `[...]` placeholders in step 3 with these values.

### Git-only

- **`AGENT_GIT_NAME`**: the bot commit author, e.g. `myagent[bot]` (any name works).
- **`GIT_USER_NAME`**: your GitHub handle, e.g. `my-git-user-name`. The agent/skill
  resolves it to the numeric id via the **public** GitHub API (`GET /users/<handle>`).
- **Optional** `AGENT_GIT_SIGNINGKEY` — only if you want the green **Verified** badge on bot commits. Without it, commits still show as `myagent[bot]` but **unverified** (grey badge) — fine to omit.
  To get Verified **without a GitHub App**: run `ssh-keygen -t ed25519 -f ~/.ssh/[AGENT_GIT_NAME]-signing -C "[AGENT_GIT_NAME]" -N ""` (replace `[AGENT_GIT_NAME]` with your bot name, e.g. `agent-laptop[bot]` → `agent-laptop[bot]-signing`) — this creates `~/.ssh/[AGENT_GIT_NAME]-signing` (private, keep it) and `.pub` (public). Paste **only** the `.pub` file — one line `ssh-ed25519 AAAA... [AGENT_GIT_NAME]` (`cat ~/.ssh/[AGENT_GIT_NAME]-signing.pub`) — as a **Signing Key** on the user's GitHub
  - **Settings → SSH and GPG keys → New SSH key → Key type: Signing Key**
  - then pass `AGENT_GIT_SIGNINGKEY="key::ssh-ed25519 AAAA... ${AGENT_GIT_NAME}"` (note the `key::` prefix + full pubkey line from the same `.pub`). The script writes it to the worktree as `gpg.format ssh` / `user.signingKey`.
  **IMPORTANT:** the private key must be loaded in `ssh-agent` for signing to work: `eval "$(ssh-agent -s)" && ssh-add ~/.ssh/${AGENT_GIT_NAME//[^a-zA-Z0-9]/-}-signing`. Add this to your shell rc so it's always available for the agent's commits.

### GitHub App

Like Git-only, but the skill mints `GH_TOKEN` for you via `mint-token.sh`. Do the one-time App setup first, then give the agent the values below.

**One-time App setup**

1. **Create the app** — GitHub → **Settings → Developer settings → GitHub Apps → New GitHub App**. For a private automation-only app set only:
   - **GitHub App name**: e.g. `myagent` (this becomes `myagent[bot]` on GitHub).
   - **Homepage URL**: required on the form — any URL works (e.g. your profile).
   - **Where can this be installed?**: *Only on this account* (keeps it private).
   - **Repository permissions**:
      - Contents → Read & write (commits/pushes)
      - Pull requests → Read & write (if the agent opens PRs)
      - Metadata → Read (always required).
   - Leave blank/unchecked:
      - Redirect URI
      - webhook (Active **off**)
      - events
      - OAuth
      - Device Flow
      - and all user/org permissions.
   - After creating, note the **App ID** shown on the app page.
2. **Generate the private key** — on the app page click **Generate a private key (PEM)**, download the `.pem`, keep it secret and store it **outside any git repo** (e.g. `~/.ssh/myagent.pem`).
3. **Install the app** — on the app page click **Install** and select the repositories the agent should touch. This grants permission; it does not change the bot name.
4. **(Optional) Verified commits** — see below; you can skip this and add it later.

**Information you then give the agent (fill the `[...]` in §3):**

- `AGENT_GIT_NAME` — the bot author, e.g. `myagent[bot]` (matches the App name).
- `GIT_USER_NAME` — the GitHub account that owns the token/App, e.g. `my-git-user-name`, that is, your username. Distinct from `AGENT_GIT_NAME` (the commit author `...[bot]`).
- `GITHUB_APP_ID` — the App ID from step 1.
- `GITHUB_APP_PEM` — path to the `.pem` from step 2 (e.g. `~/.ssh/myagent.pem`).
- `AGENT_GIT_SIGNINGKEY` *(optional)* — only if you want the green **Verified** badge; see below.

The skill mints the token at prompt time with:

```bash
source <(./mint-token.sh --app-id "$GITHUB_APP_ID" --pem "$GITHUB_APP_PEM" --shell)
# GH_TOKEN is now exported in the agent's shell (short-lived ~1h; re-run for a fresh one)
```

**Optional: verified `[bot]` badge (`AGENT_GIT_SIGNINGKEY`)**

- Without this, commits still show as `myagent[bot]` but **unverified** (grey badge) — fine for most setups.
- To get the green **Verified** badge:
  1. Run: `ssh-keygen -t ed25519 -f ~/.ssh/[AGENT_GIT_NAME]-signing -C "[AGENT_GIT_NAME]" -N ""` (replace `[AGENT_GIT_NAME]` with your bot name, e.g. `agent-laptop[bot]` → `agent-laptop[bot]-signing`) — creates `~/.ssh/[AGENT_GIT_NAME]-signing` (private, keep it) and `.pub` (public).
  2. Upload the **public** `.pub` to GitHub:
      - your App → **Settings → Developer settings → GitHub Apps → your app → Public keys / Commit signing** →
      - paste **only** `~/.ssh/${AGENT_GIT_NAME//[^a-zA-Z0-9]/-}-signing.pub` — one line `ssh-ed25519 AAAA... ${AGENT_GIT_NAME}` (`cat ~/.ssh/${AGENT_GIT_NAME//[^a-zA-Z0-9]/-}-signing.pub`; not the private file, not the fingerprint/randomart).
      - Enable commit signing if the App shows that toggle.
  3. Pass the same `.pub` line to the agent as `AGENT_GIT_SIGNINGKEY="key::ssh-ed25519 AAAA... ${AGENT_GIT_NAME}"` — note the `key::` prefix + the full pubkey line. The script writes it to the worktree's git config as `gpg.format ssh` / `user.signingKey`.
  **IMPORTANT:** the private key must be loaded in `ssh-agent` for signing to work: `eval "$(ssh-agent -s)" && ssh-add ~/.ssh/${AGENT_GIT_NAME//[^a-zA-Z0-9]/-}-signing`. Add this to your shell rc so it's always available for the agent's commits.

You can set up Verified later — omit `AGENT_GIT_SIGNINGKEY` for now and add it when you want the badge.

## 3. Paste this prompt to the agent

Pick **one** of these — whichever matches your setup. Replace every `[...]` then send the whole block (no line-deleting, no `REPO_PATH` — agent infers the current repo):

### Git-only — paste as-is (omit `AGENT_GIT_SIGNINGKEY` if you don't want Verified)

```text
Use the agent-git-setup skill. Set up a bot git identity for current repo.

AGENT_GIT_NAME=[myagent[bot]]
GIT_USER_NAME=[my-git-user-name]
AGENT_GIT_SIGNINGKEY=[key::ssh-ed25519 AAAA... myagent[bot]]

After setting the env vars above, run `agent-git-setup.sh` in the current repo.

Then do your git work inside the printed worktree. Do not touch the main tree.
```

Omit the `AGENT_GIT_SIGNINGKEY=` line entirely if you don't want the green Verified badge. Git-only Verified goes to the *user* account: **Settings → SSH and GPG keys → New SSH key → Key type: Signing Key** (not an App).

### GitHub App — paste as-is (omit `AGENT_GIT_SIGNINGKEY` if you don't want Verified)

```text
Use the agent-git-setup skill. Set up a bot git identity for current repo.

AGENT_GIT_NAME=[myagent[bot]]
GIT_USER_NAME=[my-git-user-name]
GITHUB_APP_ID=[4646191]
GITHUB_APP_PEM=[/path/to/myagent.pem]
AGENT_GIT_SIGNINGKEY=[key::ssh-ed25519 AAAA... myagent[bot]]

After setting the env vars above (mint the token first if using the GitHub App), run `agent-git-setup.sh` in the current repo.

Then do your git work inside the printed worktree. Do not touch the main tree.
```

Same omit rule for `AGENT_GIT_SIGNINGKEY`; App Verified stays **GitHub Apps → your app → Public keys / Commit signing**.

Notes:
- `GH_TOKEN` is **not** a placeholder in the prompt. For commit author alone you don't need it; for `gh`/API as the bot you do — Git-only: export `GH_TOKEN` beforehand, GitHub App: the skill mints it via `mint-token.sh --shell`.

## 4. What happens

1. (Only if you need `gh`/API as the bot) `GH_TOKEN` exported — by you (Git-only) or by `mint-token.sh` (App path). Not needed for the local commit author.
2. `GIT_USER_NAME` resolved to numeric id via the public `GET /users/$GIT_USER_NAME` (no token; `GH_TOKEN` added as Bearer only when set for higher rate limits / private).
3. `agent-git-setup.sh [REPO_PATH]` creates `.worktrees/agent` and writes
   `user.name` / `user.email` scoped to that worktree only.
4. Agent works inside the printed worktree: `commits → <name>[bot]`,
   `gh/API → <name>[bot]`, `git push → your credential` (main tree untouched).

Full details, diagrams, and reference tables are below (GitHub App setup is already in §2 above).

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
│  Token source       │  (only if you need gh/API as the bot)
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
- **Not coupled to any worktree tool.** If [treehouse](https://github.com/kunchenguid/treehouse) is installed it is used to
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

## Install

```bash
git clone https://github.com/koalyptus/agent-git-setup
# put the script on PATH (or call it by absolute path):
ln -s "$PWD/agent-git-setup.sh" ~/.local/bin/agent-git-setup.sh
# or just:  cp agent-git-setup.sh ~/.local/bin/
```

A skill definition (`skills/agent-git-setup/SKILL.md`) ships in the repo so agents that load
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
| `AGENT_GIT_NAME`     | Commit author name, e.g. `myagent[bot]`.                            |
| `GIT_USER_NAME` | GitHub handle (e.g. `my-git-user-name`) — resolved via the public GitHub API (`GET /users/<handle>` — no `GH_TOKEN` needed). |
| `GH_TOKEN`           | *(Optional)* A push-capable GitHub token (e.g. a GitHub App install token) — only for `gh`/API as the bot. Not needed for the local commit author.       |
| `GIT_USER_ID`        | *(hidden fallback)* Numeric id, alternative to `GIT_USER_NAME`. Only for hermetic tests / offline use; never in the prompt. |

The commit author (`user.name` / `user.email`) is set from the required
variables above — it is **not** optional.

### Optional: verified commit signing

| Variable              | Meaning                                                              |
|----------------------|----------------------------------------------------------------------|
| `AGENT_GIT_SIGNINGKEY` | SSH public key as `key::<pubkey>` for the green **Verified** badge. Without it commits are `myagent[bot]` but unverified. See §2 for how to generate/upload it. |

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

