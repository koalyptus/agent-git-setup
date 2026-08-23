# agent-git-setup

Give an AI agent a bot identity in local git worktrees and/or on GitHub to easily distinguish agentic authors on Git and GitHub. 

## Requirements

> **Requires git >= 2.43**: it uses `extensions.worktreeConfig` for per-worktree isolation.

- **Unix-like shell** (`bash`) and `git`. The script and tests target Linux and
  macOS. **Windows is not supported as-is** — `bash` + `git` under WSL or Git
  Bash will work, but native `cmd`/`PowerShell` will not (the script uses POSIX
  shell features and git worktree paths).
- `Make install` installs `shellcheck`/`shfmt`, `Python 3` and `cryptography` if needed.

## Install

Clone the repository:

```
git clone https://github.com/koalyptus/agent-git-setup
```

### 1. Install the skill in your harness

Pick one of these — whichever harness your agent runs in. This is a one-time
human step so the prompt in §3 ("Use the `agent-git-setup` skill…") resolves.

**Hermes:**
```bash
hermes skills install https://raw.githubusercontent.com/koalyptus/agent-git-setup/main/skills/agent-git-setup/SKILL.md
# or clone and point at the local copy:
# hermes skills install ./skills/agent-git-setup --category agent --name agent-git-setup
```
**Other harnesses (Claude Code, OpenCode, Codex, etc.):**\
Consult that harness's docs for the
exact install / "load skill from repo" command. Alternatively, copy
`skills/agent-git-setup/SKILL.md` into the harness's skills folder
(the standard `<skills>/<skill-name>/SKILL.md` layout this repo uses), or
point the harness at the raw URL above.

### 2. Prepare relevant Git information

You will fill the `[...]` placeholders in step 3 with these values.

#### Git-only

**`AGENT_GIT_NAME`**: the bot commit author, e.g. `myagent[bot]` (any name works).

**`GIT_USER_NAME`**: your GitHub handle, e.g. `my-git-user-name`.

*Optional*

`AGENT_GIT_SIGNINGKEY` — only if you want the green **Verified** badge on bot commits. Without it, commits still show as `myagent[bot]`.

To get the `Verified` badge

- Run command below by replacing `[AGENT_GIT_NAME]` your agent name stripped off the `[` and `]` special characters, e.g. `agent-laptop[bot]` → `agent-laptop-bot-signing`, to avoid file system annoyances:
```bash
ssh-keygen -t ed25519 -f ~/.ssh/[AGENT_GIT_NAME with no [] characters]-signing -C "[AGENT_GIT_NAME]" -N ""
```
- This creates `~/.ssh/[AGENT_GIT_NAME with no [] characters]-signing` (private key) and a `.pub` (public key)

- Copy **only** the `.pub` file contents, **Signing Key**, using a command for example
```bash
cat ~/.ssh/[AGENT_GIT_NAME with no [] characters]-signing.pub
```
- Then in GitHub access **Settings → SSH and GPG keys → New SSH key → Key type: Signing Key**, create a new SSH key and paste the Signing Key copied above in the `Key` textbox, make sure you use `Signing Key` key type
- Later you will assign in the prompt the same public key to `AGENT_GIT_SIGNINGKEY="key::ssh-ed25519 AAAA... ${AGENT_GIT_NAME}"`note the `key::` prefix + full pubkey line from the same `.pub`.

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
4. **(Optional) Verified commits** — see below; you can skip this and add it later.

**Information you then give the agent (fill the `[...]` in §3):**

- `AGENT_GIT_NAME` — the bot author, e.g. `myagent[bot]` (matches the App name).
- `GIT_USER_NAME` — your GitHub handle, e.g. `my-git-user-name`.
- `GITHUB_APP_ID` — the App ID from step 1.
- `GITHUB_APP_PEM` — path to the `.pem` from step 2 (e.g. `~/.ssh/myagent.pem`).
- `AGENT_GIT_SIGNINGKEY` *(optional)* — only if you want the green **Verified** badge; see below.

*Optional*

To get the green **Verified** badge:
- Run command below by replacing `[AGENT_GIT_NAME]` your agent name stripped off the `[` and `]` special characters, e.g. `agent-laptop[bot]` → `agent-laptop-bot-signing`, to avoid file system annoyances:
```bash
ssh-keygen -t ed25519 -f ~/.ssh/[AGENT_GIT_NAME with no [] characters]-signing -C "[AGENT_GIT_NAME]" -N ""
```
- This creates `~/.ssh/[AGENT_GIT_NAME with no [] characters]-signing` (private key) and a `.pub` (public key)

- Copy **only** the `.pub` file contents, **Signing Key**, using a command for example
```bash
cat ~/.ssh/[AGENT_GIT_NAME with no [] characters]-signing.pub
```

- GitHub Apps don't expose a **Public keys / Commit signing** upload for the bot (`320010330+agent-oracle-1[bot]@...` → `Unverified`). For Verified today, upload the same `.pub` to **Settings → SSH and GPG keys → Signing Key** as user `koalyptus` — then commits appear as `agent-oracle-1[bot] <8214629+koalyptus@users.noreply.github.com>` and show `Verified` (name is bot, avatar is yours). Bot-avatar `Verified` (`320010330+agent-oracle-1[bot]@...`) awaits a future GitHub UI.

- Later you will assign in the prompt the same public key to `AGENT_GIT_SIGNINGKEY="key::ssh-ed25519 AAAA... ${AGENT_GIT_NAME}"`note the `key::` prefix + full pubkey line from the same `.pub`.

You can set up Verified later — omit `AGENT_GIT_SIGNINGKEY` for now and add it when you want the badge.

### 3. Paste this prompt to the agent

Pick **one** of these — whichever matches your setup. Replace every `[...]` then send the whole block (no line-deleting, no `REPO_PATH` — agent infers the current repo):

#### Git-only

Use the prompt below with replaced values prepared in step 2, omit `AGENT_GIT_SIGNINGKEY` if you don't want Verified commits.

```text
Use the agent-git-setup skill. Set up a bot git identity for current repo.

AGENT_GIT_NAME=[myagent[bot]]
GIT_USER_NAME=[my-git-user-name]
AGENT_GIT_SIGNINGKEY=[key::ssh-ed25519 AAAA... myagent[bot]]

After setting the env vars above, run `agent-git-setup.sh` in the current repo.

Then do your git work inside the printed worktree. Do not touch the main tree.
```

Omit the `AGENT_GIT_SIGNINGKEY=` line entirely if you don't want the green Verified badge. Git-only Verified goes to the *user* account: **Settings → SSH and GPG keys → New SSH key → Key type: Signing Key** (not an App).

#### GitHub App

Use the prompt below with replaced values prepared in step 2, omit `AGENT_GIT_SIGNINGKEY` if you don't want Verified commits.

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

## 4. What happens

1. The agent authenticates itself if needed. If it has to use GitHub (open PRs, comment on issues), it creates its own short-lived token — you don't provide one. If it only makes local commits, no token is needed at all.

2. The agent resolves the noreply identity. **Git-only** (no `GH_TOKEN`): your handle `GIT_USER_NAME` (e.g. `koalyptus`) → `8214629+koalyptus@users.noreply.github.com` (Verified on your account). **GitHub App** (`GH_TOKEN` set): the bot itself `AGENT_GIT_NAME` (e.g. `agent-oracle-1[bot]`) → `320010330+agent-oracle-1[bot]@users.noreply.github.com` (Verified as the bot `agent-oracle-1[bot]`, not `koalyptus`). Public `GET /users/<bot>` (`%5B%5D`-encoded) provides the bot id.

3. The agent creates an isolated worktree (standalone: `~/.agent-git-setup/<repo>/agent`; with [treehouse](https://github.com/kunchenguid/treehouse): the treehouse pool) and sets the bot identity only there. Requires git ≥ 2.43. It prints isolation verified — main tree untouched on success; if it prints ERROR, update git and re-run.

4. The agent does all its work inside that worktree. Commits appear as {agent-name}[bot] (Git-only: `koalyptus` noreply, Verified on your account; App: bot noreply, Verified as `agent-oracle-1[bot]`), GitHub actions appear as {agent-name}[bot] (when a token was needed), and git push still uses your account. Your main checkout is never changed.

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
│  git worktree add   │  → ~/.agent-git-setup/<repo>/agent (or treehouse pool)
│  write worktree     │     .git/worktrees/agent/config
│    user.name        │     user.name = <name>[bot] (history reads as bot)
│    user.email       │     user.email = <id>+<GIT_USER_NAME or bot>[bot]@... (Git-only: +koalyptus, App: +bot, both verify)
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

- The script enables the git `worktreeConfig` extension (`extensions.worktreeConfig=true` in the main repo config). On git 2.43+ this is **required** for the per-worktree config file at `.git/worktrees/<name>/config` to be read at all; without it the bot identity still leaks into the shared main config (the failure seen on the laptop). The script exits with an error if it cannot enable the extension, and after writing it prints an isolation check (`worktree user.name` = bot, `main tree user.name` = human) that fails loudly if the worktree config is not being read.
- Rewriting `origin` to inject a token would change your main tree too — exactly what we avoid. The script does **not** set `remote.origin.url` in the worktree config; it only sets `user.name`/`user.email` (and optionally SSH signing). The bot actor for `gh`/API (PRs, issues, comments) is provided by `GH_TOKEN` in the agent's environment — **not** by rewriting `origin`. Plain `git push` uses the repo's normal credential (the push actor is you, unless your push mechanism also uses `GH_TOKEN`). The agent must not rewrite `origin` either (see the skill).
- **Result:** commits authored in the worktree show as `<name>[bot]`. Plain `git push` uses the repo's normal credential. `gh`/API calls (PRs, issues, comments) made with `GH_TOKEN` in the agent's environment are the bot.

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
| `AGENT_GIT_NAME`     | Commit author name, e.g. `myagent[bot]`. For App, matches `<App name>[bot]` so author equals the bot that owns the token. |
| `GIT_USER_NAME` | GitHub handle (e.g. `my-git-user-name`) — resolved via `GET /users/<handle>` for **Git-only** → `id+my-git-user-name@...` (human noreply). For **App** (`GH_TOKEN` set) the bot itself (`AGENT_GIT_NAME` → `320010330+agent-oracle-1[bot]@...`) is resolved via `GET /users/<agent>[bot]` to the bot id, so commits appear as the bot. |
| `GH_TOKEN`           | *(Optional)* A push-capable GitHub token (e.g. a GitHub App install token) — only for `gh`/API as the bot. Not needed for the local commit author.       |
| `GIT_USER_ID`        | *(hidden fallback)* Numeric id, alternative to `GIT_USER_NAME`. Only for hermetic tests / offline use; never in the prompt. |
| `AGENT_GIT_BOT_ID`   | *(hidden fallback)* Bot id for App path. Only for hermetic tests; offline. Never in prompt. |

The commit author (`user.name` / `user.email`) is set from the required
variables above — it is **not** optional.

### Optional: verified commit signing

| Variable              | Meaning                                                              |
|----------------------|----------------------------------------------------------------------|
| `AGENT_GIT_SIGNINGKEY` | SSH public key as `key::<pubkey>` for the green **Verified** badge. Without it commits are `myagent[bot]` but unverified. Git-only: upload `.pub` as **Signing Key** on user (**SSH and GPG keys**); App: upload same `.pub` as **Public keys / Commit signing** on the App. Mismatch (e.g. bot noreply with user Signing Key) shows `Unverified / unknown_key`. See §2. |

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
export GIT_USER_NAME="my-git-user-name"           # handle; script/skill resolves to numeric id (Git-only: human, App: bot)
export AGENT_GIT_SIGNINGKEY="key::ssh-ed25519 AAAA... bot@github"  # optional

agent-git-setup.sh ~/dev/my-repo
# -> worktree at ~/.agent-git-setup/my-repo/agent (or treehouse pool)
#    commits there: myagent[bot] <id+my-git-user-name@users.noreply.github.com>  (Git-only)
#               or: myagent[bot] <bot-id+myagent[bot]@users.noreply.github.com> (App: bot noreply → Verified as bot)
#                  (user.name = myagent[bot] so history still reads as the bot;
#                   email is GIT_USER_NAME for Git-only, bot for App — both verify when
#                   the same .pub is uploaded to the correct place: user Signing Key vs App Public keys)
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

