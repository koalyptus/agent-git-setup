SCRIPT := scripts/agent-git-setup.sh
MINT := scripts/mint-token.sh
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
	@for py in python3 python; do \
	  if command -v $$py >/dev/null 2>&1 && $$py -c "import cryptography" >/dev/null 2>&1; then \
	    echo "python3+cryptography: ok ($$py $$($$py -c 'import sys; print(sys.version.split()[0])') / cryptography $$($$py -c 'import cryptography; print(cryptography.__version__)'))"; \
	    break; \
	  fi; \
	done || \
	  (echo "python3+cryptography: installing…" && \
	   if command -v brew >/dev/null 2>&1; then brew install python3@3.12 && pip3 install --quiet cryptography || pip install --quiet cryptography; \
	   elif command -v apt-get >/dev/null 2>&1; then sudo apt-get install -y -qq python3 python3-pip && pip3 install --quiet cryptography || pip install --quiet cryptography; \
	   else echo "no brew/apt found — install python3 + pip then: pip install cryptography"; exit 1; fi && \
	   echo "python3+cryptography: installed")

# Run everything CI runs, locally, before pushing.
ci: test lint
