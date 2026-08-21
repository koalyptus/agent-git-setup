SCRIPT := agent-git-setup.sh
MINT := mint-token.sh
TEST_DIR := tests
TEST := $(TEST_DIR)/agent-git-setup-test.sh
MINT_TEST := $(TEST_DIR)/mint-token-test.sh

.PHONY: test lint tools-install ci

test:
	bash $(TEST)
	bash $(MINT_TEST)

lint:
	shellcheck $(SCRIPT) $(MINT) $(TEST) $(MINT_TEST)
	shfmt -d $(SCRIPT) $(MINT) $(TEST) $(MINT_TEST)

tools-install:
	@command -v shellcheck >/dev/null 2>&1 && echo "shellcheck: ok ($$(shellcheck --version | head -1))" || (echo "shellcheck: installing…" && sudo apt-get update -qq && sudo apt-get install -y -qq shellcheck && echo "shellcheck: installed")
	@command -v shfmt >/dev/null 2>&1 && echo "shfmt: ok ($$(shfmt --version))" || (echo "shfmt: installing via webi.sh…" && curl -sS https://webi.sh/shfmt | sh && echo "shfmt: installed (add ~/.local/bin to PATH if needed: export PATH=\"\$$HOME/.local/bin:\$$PATH\")")

# Run everything CI runs, locally, before pushing.
ci: test lint
