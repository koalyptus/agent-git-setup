# agent-git-setup

This repository provides a way to clearly identify agentic work in Git and GitHub. It provides setup and preflight tools for agents using Git and GitHub. When an agent creates or selects a worktree for a task, use these tools to configure bot identity for commits and give the agent a GitHub App bot identity for `gh` and API interactions, using a short-lived token. This tool is harness agnostic and does not prescribe usage of linked worktrees. If the harness decides to use worktrees then agentic work will be clearly attributed to the agent identity.

## Choose a skill

| Skill | When to use it | What it does |
|---|---|---|
| `agent-git-setup` | When a repo does not yet have bot identity setup for Git and GitHub. | Sets bot commit identity once for every current and future linked agent worktree, leaving the main tree's existing identity unchanged. Its GitHub mode can also mint a short-lived token and preflight API access. |
| `agent-github-access` | Before authorizing GitHub CLI/API work when you do not need to configure bot commit identity. | Mints a short-lived (about one hour) App installation token and verifies access to the current repository. |
| `agent-git-override-main-identity` | When the user explicitly wants bot-attributed commits from the main worktree. | Temporarily replaces this clone's main-worktree `user.name` and `user.email` with the persisted bot identity. The change remains active until restored. |
| `agent-git-restore-main-identity` | After the main-worktree bot identity is no longer wanted. | Restores the saved repo-local identity, refusing to overwrite identity changes made since activation. |

The two main-identity skills are optional and do not change `agent-git-setup` behavior. They modify only this clone's `.git/config`; global Git config and other repositories are untouched. While enabled, commits made from this repository's main worktree use the bot identity, including human-made commits. Run the restore skill before making human-attributed commits here.

If you decide to have both bot-authored commits and bot-authenticated API calls, use `agent-git-setup`'s `GitHub` mode; its workflow covers both. Use `agent-github-access` by itself for subsequent `gh` commands or GitHub API-only access.

Note: none of these skills configures `git push` authentication, which continues to use Git's configured credential.

`agent-github-access` is a just-in-time step, not a permanent authorization. Run it and confirm repository access **before** assigning GitHub CLI/API work to the agent. If no explicit or default credentials select an App and several per-App files exist, the skill asks which public App ID to use; it never guesses. Mint a fresh token for each later session, or when the current token expires.

## Requirements

- `git >= 2.43`
- `gh` (GitHub CLI) — required for GitHub-mode preflight and bot GitHub operations; Git-only mode does not need it
- Network access to GitHub for automatic bot identity lookup; Bash setup also requires `curl` + `python3` for the lookup
- `python3` + `cryptography` — required by the Bash token minter and GitHub-mode Bash attestation verification; not required for the native Windows path
- PowerShell 7+ (`pwsh.exe`) — required for native Windows setup and token minting. Run the native Windows workflow in a PowerShell 7 session.

## Install

Clone the repository:

```
git clone https://github.com/koalyptus/agent-git-setup
```

### 1. Install the skills you need in your harness

Consult that harness's docs for the exact install / "load skill from repo" command. Install `agent-git-setup` and `agent-github-access`; install the main-identity skills only if you want their opt-in workflow. When copying manually, include each installed skill's `scripts/` directory. If loading a raw `SKILL.md`, make its bundled scripts available at the installed skill path too.

```
https://raw.githubusercontent.com/koalyptus/agent-git-setup/main/skills/agent-git-setup/SKILL.md

https://raw.githubusercontent.com/koalyptus/agent-git-setup/main/skills/agent-github-access/SKILL.md

https://raw.githubusercontent.com/koalyptus/agent-git-setup/main/skills/agent-git-override-main-identity/SKILL.md

https://raw.githubusercontent.com/koalyptus/agent-git-setup/main/skills/agent-git-restore-main-identity/SKILL.md
```

### 2. Prepare relevant Git/GitHub information

There are two flows: `Git-only` and `GitHub App`.
`Git-only` assigns the provided agent identity to Git commits only.

#### Git-only

**`AGENT_GIT_NAME`**: the bot's GitHub login, e.g. `myagent[bot]`.

The bot account identity is resolved automatically from GitHub.

#### GitHub App

You need a GitHub App (with its PEM) and its App ID. If you already have one,
skip next section below. To create one, see the steps under "Creating a GitHub
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

The `agent-github-access` skill reads the App ID and PEM path from the
existing agent-git-setup credentials configuration. Keep the configuration and
PEM outside repositories; do not include either value in the agent prompt.

For commit attribution, provide `AGENT_GIT_NAME` (the bot login, normally `<app-slug>[bot]`) to `agent-git-setup`. GitHub API access uses the App actor from the minted token and does not require `AGENT_GIT_NAME`.

### 3. Prompt the agent

Use the Git-only prompt once when enabling bot commit attribution for this
repository. If the agent needs both bot commits and API access, follow the
GitHub App workflow in `agent-git-setup`. Use the standalone access prompt
before assigning API-only work where commit identity should remain unchanged.

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

Note: Once setup is done, run the access skill `agent-github-access` before asking the agent to perform GitHub CLI/API actions. It uses the App credentials already selected by the harness or configured for the minter. The minter creates an installation-scoped token that lasts about one hour, and the skill verifies access to the current repository.

If bot identity setup or access fails, the skill reports the reason and asks
before using the configured human identity as a last resort. Approval is
session-scoped; declining or failing to verify the selected identity aborts
that workflow. The setup scripts themselves remain bot-only and never silently
fall back.

## 4. What happens

See [`skills/agent-git-setup/SKILL.md`](skills/agent-git-setup/SKILL.md) for commit attribution and preflight and [`skills/agent-github-access/SKILL.md`](skills/agent-github-access/SKILL.md) for GitHub API access.

### Agent git setup flow

```
┌──────────────────────────────────────┐
│              Prompt                  │
│   ────────────────────────────────   │
│   "Use agent-git-setup skill."       │
└──────────────┬───────────────────────┘
               │
               ▼
┌──────────────────────────────────────┐
│           Token source               │  (only for gh/API agent identity)
│   ────────────────────────────────   │
│     scripts/mint-token.sh            │   scripts/mint-token.sh + GitHub App
│     --app-id --pem                   │    (create app, download PEM,
│     --shell                          │     install; setup resolves identity)
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

### GitHub access flow

This flow covers `gh` and GitHub API calls only. It does not set commit identity or configure pushes.

```
┌────────────────────────────────────────────┐
│ Current repository + existing App config   │
└──────────────────────┬─────────────────────┘
                       ▼
┌────────────────────────────────────────────┐
│ Resolve App credentials                    │
│ Harness selection → default → per-App files│
└──────────────┬─────────────────────┬───────┘
               │ Selected            │ None / ambiguous
               ▼                     ▼
┌──────────────────────────────┐  ┌──────────────────────┐
│ Run platform minter in the   │  │ Stop if none; ask    │
│ agent's active shell process │  │ which App if several │
└──────────────┬───────────────┘  └──────────────────────┘
               │ GH_TOKEN + signed actor attestation
               ▼
┌────────────────────────────────────────────┐
│ Verify installation-token access to repo   │
│ with gh repo view                          │
└──────────────┬─────────────────────┬───────┘
               │ Verified            │ Failed
               ▼                     ▼
┌──────────────────────────────┐  ┌──────────────────────────────┐
│ Requested gh/API actions     │  │ Explain failure and ask for  │
│ as the App bot               │  │ explicit human approval      │
└──────────────────────────────┘  └──────────────┬───────────────┘
                                                 ▼
               ┌────────────────────────────────────┐
               │          Approved?                 │
               └──────────────┬───────────────────┬─┘
                              │ Yes               │ No
                              ▼                   ▼
          ┌──────────────────────────────┐  ┌──────────────────┐
          │ Clear bot-token variables;   │  │ Stop; no GitHub  │
          │ verify human login + repo    │  │ changes          │
          └──────────────┬───────────────┘  └──────────────────┘
                         ▼
          ┌──────────────────────────────┐
          │ Approved API actions as      │
          │ human for this session       │
          └──────────────────────────────┘
```

## Behavior

- Setup writes the bot's `user.name` and GitHub noreply email to shared repo config for linked worktrees. The main checkout keeps its existing Git identity; the setup leaves its local identity and global Git config untouched.
- GitHub-mode preflight verifies a signed App installation token and access to the target worktree's `origin`. `gh` uses `GH_TOKEN`; other API clients must pass it explicitly. Bot-user tokens are not supported.
- `agent-github-access` mints a token using the App installation already selected by the harness and verifies access to the current repository. The token's repository scope is controlled by the App installation's GitHub settings, not narrowed by this check.
- If bot setup or access fails, the corresponding skill must surface the error and obtain explicit, session-scoped human approval before using an existing human identity. No approval means stop; no identity or credential config is changed for fallback.
- The script does not manage worktrees, hooks, remotes, or push credentials. The harness owns lifecycle enforcement. Push identity follows Git's configured credential, normally the user's existing credential; a helper configured with the App token can push as the bot.

## Validation

`make test` runs hermetic Bash, PowerShell (if available), agent GitHub access,
and token-minter suites using temporary repos and synthetic credentials. CI
runs the Bash access workflow on Linux and the native PowerShell access workflow
on Windows.

| Command | Purpose |
|---|---|
| `make test` | Run all test suites. |
| `make lint` | Run ShellCheck, shfmt, and PSScriptAnalyzer (when available). |
| `make install` | Install supported local lint/test dependencies. |
| `make ci` | Run sync check, tests, and lint; use as the pre-push gate. |

Root scripts in `scripts/` are canonical; harnesses use bundled copies under
the corresponding skill's `scripts/` directory. After changing a root script, run
`make sync-skill-scripts`; `make ci` checks for bundle drift.

## Commands

To enable bot-attributed commits, run setup once for this repository checkout; the harness creates and manages linked worktrees, and the shared conditional Git config applies to all of them, including ones created later. The harness should run the matching preflight in the selected worktree before each task that needs bot identity:

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