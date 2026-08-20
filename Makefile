SCRIPT := agent-git-setup.sh
TEST := agent-git-setup-test.sh
MINT := mint-token.sh
MINT_TEST := mint-token-test.sh

.PHONY: test lint ci

test:
	bash $(TEST)
	bash $(MINT_TEST)

lint:
	shellcheck $(SCRIPT) $(TEST) $(MINT) $(MINT_TEST)
	shfmt -d $(SCRIPT) $(TEST) $(MINT) $(MINT_TEST)

# Run everything CI runs, locally, before pushing.
ci: test lint
