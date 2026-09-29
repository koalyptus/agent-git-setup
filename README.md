# agent-git-setup

Give an AI agent a bot identity so its git commits and GitHub actions are clearly attributed to the agent, distinct from your account. The harness creates and selects the worktree; this repo scopes one bot identity to every linked worktree in that clone.

## Requirements

- `git >= 2.43`
- `gh` (GitHub CLI) — required for GitHub-mode preflight and bot GitHub operations; Git-only mode does not need it
- Network access to GitHub for automatic bot identity lookup; Bash setup also requires `curl` + `python3` for the lookup
- `python3` + `cryptography` — required by Bash GitHub-mode attestation verification and `scripts/mint-token.sh`; Git-only mode does not need it

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

#### Git-only

**`AGENT_GIT_NAME`**: the bot's GitHub login, e.g. `myagent[bot]`.

The bot account identity is resolved automatically from GitHub.

#### GitHub App

You need a GitHub App (with its PEM) and its App ID. If you already have one,
skip to the values below. To create one, see the steps under "Creating a GitHub
App".

**Creating a GitHub App** (one-time, if not already done)

1. **Create the app** — GitHub → **Settings → Developer settings → GitHub Apps → New GitHub App**. For a private automation-only app set only:
   - **GitHub App name**: choose a name whose App slug matches the bot login you want (for example, slug `myagent` gives `myagent[bot]` for `AGENT_GIT_NAME`).
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

**Information you then give the agent:**

- `AGENT_GIT_NAME` — the bot author, e.g. `myagent[bot]` (matches the App name).
- `GITHUB_APP_ID` — the App ID from step 1.
- `GITHUB_APP_PEM` — path to the `.pem` from step 2 (e.g. `~/.ssh/myagent.pem`).

### 3. Paste this prompt to the agent

Pick **one** of these — whichever matches your setup. Replace every `[...]` then send the whole block (no line-deleting). Each prompt targets the current repo:

#### Git-only

```text
Use the agent-git-setup skill. Set up a bot git identity for current repo.

AGENT_GIT_NAME=myagent[bot]   # replace with your bot's name (e.g. myagent → myagent[bot])
```

#### GitHub App

```text
Use the agent-git-setup skill. Set up a bot git identity for current repo.

AGENT_GIT_NAME=myagent[bot]   # replace with your bot's name (e.g. myagent → myagent[bot])
GITHUB_APP_ID=[1234567]
GITHUB_APP_PEM=[/path/to/myagent.pem]
```

Note: the agent writes the one-time credentials file itself from the `GITHUB_APP_ID` / `GITHUB_APP_PEM` values in your prompt. For multiple bot identities (one per repo), it writes `credentials.d/credentials-<APP_ID>.env` files keyed by App ID. `mint-token.sh` selects the matching file when the App ID from the current prompt is supplied; no name-to-App-ID mapping is needed. The file created by the skill contains only the public App ID and the **path** to the PEM you already downloaded, never the PEM bytes or a live token. For each GitHub session, the skill mints a fresh `GH_TOKEN`; you do **not** provide or store a token per session.

## 4. What happens

See [`skills/agent-git-setup/SKILL.md`](skills/agent-git-setup/SKILL.md) for the full workflow.

## Flow diagram (happy path)

```
┌──────────────────────────────────────┐
│              Prompt                  │
│   ────────────────────────────────   │
│   "Use agent-git-setup skill on      │
│    <repo-path>"                      │
└──────────────┬───────────────────────┘
               │
               ▼
┌──────────────────────────────────────┐
│           Token source               │  (only if you need gh/API as the bot)
│   ────────────────────────────────   │
│   Option A:                          │  scripts/mint-token.sh + GitHub App
│     scripts/mint-token.sh            │    (create app, download PEM,
│     --app-id --pem                   │     install; setup resolves identity
│     --shell                          │
│   Option B:                          │  Another trusted App-token provider
│     your token minter                │    (signed attestation required)
└──────────────┬───────────────────────┘
               │ exports GH_TOKEN + attestation
               ▼
┌──────────────────────────────────────┐
│       Runtime environment            │
│   ────────────────────────────────   │
│   AGENT_GIT_NAME                     │  (agent)
│   GH_TOKEN + signed AGENT_GIT_TOKEN_*│  (GitHub mode)
└──────────────┬───────────────────────┘
               │
               ▼
┌──────────────────────────────────────┐
│   scripts/agent-git-setup.sh         │
│   ────────────────────────────────   │
│   setup once; preflight before work  │
│   writes ONE bot-identity config     │  .git/agent-bot-identity.config
│     in .git/, included for ALL       │  + includeIf "gitdir/i:**/.git/
│     worktrees via includeIf          │    worktrees/**" in .git/config
│     user.name = <name>[bot]          │     (main repo .git is excluded
│     user.email = (bot noreply)       │      by the glob → stays yours)
└──────────────┬───────────────────────┘
               │
               ▼
┌──────────────────────────────────────┐
│      Agent works in the worktree     │
│   ────────────────────────────────   │
│   commits → <name>[bot] (no badge)   │
│   gh/API   → <name>[bot] (GH_TOKEN)  │
│   git push → configured credential   │
└──────────────────────────────────────┘
```

## Behavior

- Setup writes the bot's `user.name` and GitHub noreply email to shared repo config for linked worktrees. The main checkout and global Git config remain untouched.
- GitHub-mode preflight verifies a signed App installation token and access to the target worktree's `origin`. `gh` uses `GH_TOKEN`; other API clients must pass it explicitly. Bot-user tokens are not supported.
- The script does not manage worktrees, hooks, remotes, or push credentials. The harness owns lifecycle enforcement. Push identity follows Git's configured credential, normally the user's existing credential; a helper configured with the App token can push as the bot.

## Validation

`make test` runs hermetic Bash, PowerShell (if available), and token-minter
suites using temporary repos and synthetic credentials. CI runs the same tests.

| Command | Purpose |
|---|---|
| `make test` | Run all test suites. |
| `make lint` | Run ShellCheck, shfmt, and PSScriptAnalyzer (when available). |
| `make install` | Install supported local lint/test dependencies. |
| `make ci` | Run sync check, tests, and lint; use as the pre-push gate. |

Root scripts in `scripts/` are canonical; harnesses use bundled copies under
`skills/agent-git-setup/scripts/`. After changing a root script, run
`make sync-skill-scripts`; `make ci` checks for bundle drift.

## Commands

Run setup once per clone, then preflight in the linked worktree before work:

```bash
scripts/agent-git-setup.sh <repo-dir>
scripts/agent-git-setup.sh --preflight --mode git-only <worktree>
scripts/agent-git-setup.sh --preflight --mode github <worktree>
```

On Windows, use `scripts/agent-git-setup.ps1` with the same arguments. Full
token-provider, environment, and lifecycle details are in the
[skill guide](skills/agent-git-setup/SKILL.md); Windows-specific notes are in
[doc/windows-support.md](doc/windows-support.md).

## License

MIT.