SCRIPT := agent-git-setup.sh
MINT := mint-token.sh
TEST_DIR := tests
TEST := $(TEST_DIR)/agent-git-setup-test.sh
MINT_TEST := $(TEST_DIR)/mint-token-test.sh

.PHONY: test lint install ci

test:
	bash $(TEST)
	bash $(MINT_TEST)

lint:
	shellcheck $(SCRIPT) $(MINT) $(TEST) $(MINT_TEST)
	shfmt -d $(SCRIPT) $(MINT) $(TEST) $(MINT_TEST)

install:
	@command -v shellcheck >/dev/null 2>&1 && echo "shellcheck: ok ($$(shellcheck --version | head -1))" || \
	  (echo "shellcheck: installing…" && \
	   if command -v brew >/dev/null 2>&1; then brew install shellcheck; \
	   elif command -v apt-get >/dev/null 2>&1; then sudo apt-get update -qq && sudo apt-get install -y -qq shellcheck; \
	   else echo "no brew/apt found — install shellcheck manually: https://github.com/koalaman/shellcheck#installing"; exit 1; fi && \
	   echo "shellcheck: installed")
	@command -v shfmt >/dev/null 2>&1 && echo "shfmt: ok ($$(shfmt --version))" || \
	  (echo "shfmt: installing…" && \
	   if command -v brew >/dev/null 2>&1; then brew install shfmt; \
	   else curl -sS https://webi.sh/shfmt | sh; fi && \
	   echo "shfmt: installed (if via webi.sh, add ~/.local/bin to PATH: export PATH=\"\$$HOME/.local/bin:\$$PATH\")")

# Run everything CI runs, locally, before pushing.
ci: test lint
