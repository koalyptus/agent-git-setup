SCRIPT := scripts/agent-git-setup.sh
PSCRIPT := scripts/agent-git-setup.ps1
MINT := scripts/mint-token.sh
TEST_DIR := tests
TEST := $(TEST_DIR)/agent-git-setup-test.sh
PTEST := $(TEST_DIR)/agent-git-setup-test.ps1
MINT_TEST := $(TEST_DIR)/mint-token-test.sh

# Bundle copies used by `hermes skills install github/koalyptus/agent-git-setup`.
# Source of truth is the files in scripts/. This target keeps the bundle in sync.
SKILL_DIR := skills/agent-git-setup
SKILL_SCRIPTS_DIR := $(SKILL_DIR)/scripts
SKILL_BUNDLE := $(SKILL_SCRIPTS_DIR)/agent-git-setup.sh $(SKILL_SCRIPTS_DIR)/agent-git-setup.ps1 $(SKILL_SCRIPTS_DIR)/mint-token.sh

.PHONY: test lint install ci sync-skill-scripts sync-check

test:
	bash $(TEST)
	@if command -v pwsh >/dev/null 2>&1; then pwsh $(PTEST); else echo "pwsh not found — skipping PowerShell tests"; fi
	bash $(MINT_TEST)

lint:
	shellcheck $(SCRIPT) $(MINT) $(TEST) $(MINT_TEST)
	shfmt -d $(SCRIPT) $(MINT) $(TEST) $(MINT_TEST)
	@if command -v pwsh >/dev/null 2>&1; then pwsh scripts/lint-ps1.ps1 $(PSCRIPT) $(PTEST); else echo "pwsh not found — skipping PSScriptAnalyzer"; fi

lint-bash:
	shellcheck $(SCRIPT) $(MINT) $(TEST) $(MINT_TEST)
	shfmt -d $(SCRIPT) $(MINT) $(TEST) $(MINT_TEST)

install:
	@command -v shellcheck >/dev/null 2>&1 && echo "shellcheck: ok ($$(shellcheck --version | head -1))" || \
	  (echo "shellcheck: installing…" && \
	   if command -v brew >/dev/null 2>&1; then brew install shellcheck; \
	   elif command -v apt-get >/dev/null 2>&1; then sudo apt-get update -qq && sudo apt-get install -y -qq shellcheck; \
	   else echo "no brew/apt found — install shellcheck manually: https://github.com/koalaman/shellcheck#installing" && exit 1; fi && \
	   echo "shellcheck: installed")
	@command -v shfmt >/dev/null 2>&1 && echo "shfmt: ok ($$(shfmt --version))" || \
	  (echo "shfmt: installing…" && \
	   if command -v brew >/dev/null 2>&1; then brew install shfmt; \
	   else curl -sS https://webi.sh/shfmt | sh; fi && \
	   echo "shfmt: installed (if via webi.sh, add ~/.local/bin to PATH: export PATH=\"$$HOME/.local/bin:$$PATH\")")
	@command -v pwsh >/dev/null 2>&1 && echo "pwsh: ok ($$(pwsh -Command '\$PSVersionTable.PSVersion.ToString()'))" || \
	  (echo "pwsh: installing…" && \
	   if command -v brew >/dev/null 2>&1; then brew install --cask powershell; \
	   elif command -v apt-get >/dev/null 2>&1; then sudo apt-get update -qq && sudo apt-get install -y -qq powershell; \
	   else echo "no brew/apt found — install PowerShell manually: https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-linux" && exit 1; fi && \
	   echo "pwsh: installed")
	@for py in python3 python; do \
	  if command -v $$py >/dev/null 2>&1 && $$py -c "import cryptography" >/dev/null 2>&1; then \
	    echo "python3+cryptography: ok ($$py $$($$py -c 'import sys; print(sys.version.split()[0])') / cryptography $$($$py -c 'import cryptography; print(cryptography.__version__)'))"; \
	    break; \
	  fi; \
	done || \
	  (echo "python3+cryptography: installing…" && \
	   if command -v brew >/dev/null 2>&1; then brew install python3@3.12 && pip3 install --quiet cryptography || pip install --quiet cryptography; \
	   elif command -v apt-get >/dev/null 2>&1; then sudo apt-get install -y -qq python3 python3-pip && pip3 install --quiet cryptography || pip install --quiet cryptography; \
	   else echo "no brew/apt found — install python3 + pip then: pip install cryptography" && exit 1; fi && \
	   echo "python3+cryptography: installed")

# Copy the two source-of-truth scripts into the skill bundle.
# Run this whenever you change a script at the repo root. `make ci` will not
# do it for you — it runs `sync-check` first and fails if the bundle drifted,
# forcing you to run `sync-skill-scripts` consciously (so the bundle change
# ends up in the same commit as the source change, by intention).
sync-skill-scripts:
	@mkdir -p $(SKILL_SCRIPTS_DIR)
	# Use cmp to skip the cp when content is already identical, so re-running
	# the target is a no-op at the git level (no spurious mtime churn).
	@for pair in "$(SCRIPT) $(SKILL_SCRIPTS_DIR)/agent-git-setup.sh" \
	             "$(PSCRIPT) $(SKILL_SCRIPTS_DIR)/agent-git-setup.ps1" \
	             "$(MINT) $(SKILL_SCRIPTS_DIR)/mint-token.sh"; do \
	  set -- $$pair; \
	  if cmp -s "$$1" "$$2"; then echo "ok   - $$2 already in sync"; \
	  else cp "$$1" "$$2" && echo "synced $$1 -> $$2"; fi; \
	done

# Verify the skill bundle matches the source-of-truth scripts. Run by
# `make ci` before test/lint. Fails loudly (with a diff) if they have drifted;
# the fix is to run `make sync-skill-scripts` and commit the bundle copy.
sync-check:
	@status=0; \
	for pair in "$(SCRIPT) $(SKILL_SCRIPTS_DIR)/agent-git-setup.sh" \
	            "$(PSCRIPT) $(SKILL_SCRIPTS_DIR)/agent-git-setup.ps1" \
	            "$(MINT) $(SKILL_SCRIPTS_DIR)/mint-token.sh"; do \
	  src="$${pair%% *}"; dst="$${pair##* }"; \
	  if [ ! -f "$$dst" ]; then \
	    echo "FAIL: $$dst is missing. Run: make sync-skill-scripts" >&2; \
	    status=1; continue; \
	  fi; \
	  if ! diff -q "$$src" "$$dst" >/dev/null 2>&1; then \
	    echo "FAIL: $$dst is out of sync with $$src" >&2; \
	    diff "$$src" "$$dst" >&2 || true; \
	    echo "  fix: make sync-skill-scripts && git add $$dst" >&2; \
	    status=1; \
	  else \
	    echo "ok   - $$dst in sync"; \
	  fi; \
	done; \
	exit $$status

# Run everything CI runs, locally, before pushing.
ci: sync-check test lint

# Cut a release: tag main (must be clean + synced with origin/main) and create
# a GitHub Release with auto-generated notes. Usage: make release VERSION=x.y.z
# Requires `gh` authenticated and the working tree on `main`, up to date.
.PHONY: release
release:
	@test -n "$(VERSION)" || { echo "usage: make release VERSION=x.y.z" >&2; exit 1; }
	@test "$$(git rev-parse --abbrev-ref HEAD)" = "main" || { echo "release must run on main (currently $$(git rev-parse --abbrev-ref HEAD))" >&2; exit 1; }
	@git fetch origin main >/dev/null 2>&1
	@git merge --ff-only origin/main >/dev/null 2>&1 || { echo "main is not up to date with origin/main (fetch + ff failed)" >&2; exit 1; }
	@git diff --quiet || { echo "working tree is dirty; commit or stash first" >&2; exit 1; }
	@git rev-parse -q --verify "v$(VERSION)" >/dev/null && { echo "tag v$(VERSION) already exists" >&2; exit 1; } || true
	git tag -a "v$(VERSION)" -m "Release v$(VERSION)"
	git push --tags
	gh release create "v$(VERSION)" --generate-notes
	@echo "released v$(VERSION)"
