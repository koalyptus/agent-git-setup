---
name: agent-git-restore-main-identity
description: "Restore this repository's saved main-worktree Git identity after an opt-in bot identity override."
version: 1.0.0
author: koalyptus
license: MIT
platforms: [linux, macos, windows]
---

# Restore Main-Worktree Identity

Restore the repo-local identity saved by `agent-git-override-main-identity`. This affects only the current clone; global Git config is never changed.

## Workflow

1. Confirm the human wants the original identity restored in this repository.
2. Set `SKILL_DIR` to this skill's installation directory, resolved from the loaded `SKILL.md` path. Use the helper bundled there, not a `scripts/` path relative to the target repository. Do not ask the human for the skill path. Run with the target main worktree as the current directory and explicit target (`.`). On Linux or macOS:

   ```bash
   bash "$SKILL_DIR/scripts/agent-git-restore-main-identity.sh" --confirm .
   ```

   On Windows:

   ```powershell
   pwsh "$SKILL_DIR/scripts/agent-git-restore-main-identity.ps1" --confirm .
   ```

3. Verify `git var GIT_AUTHOR_IDENT` and `git var GIT_COMMITTER_IDENT` resolve to the restored identity, and report the result.

The script restores the exact prior local values, or removes the temporary local values if none existed before the override. It refuses to overwrite identity values changed since activation. If it refuses, preserve `.git/agent-main-identity.backup.config`, explain the conflict, and ask the human how to proceed; do not force restoration or delete the backup.