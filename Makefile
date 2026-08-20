SCRIPT := agent-git-setup.sh
MINT := mint-token.sh
TEST_DIR := tests
TEST := $(TEST_DIR)/agent-git-setup-test.sh
MINT_TEST := $(TEST_DIR)/mint-token-test.sh

.PHONY: test lint ci

test:
	bash $(TEST)
	bash $(MINT_TEST)

lint:
	shellcheck $(SCRIPT) $(MINT) $(TEST) $(MINT_TEST)
	shfmt -d $(SCRIPT) $(MINT) $(TEST) $(MINT_TEST)

# Run everything CI runs, locally, before pushing.
ci: test lint
