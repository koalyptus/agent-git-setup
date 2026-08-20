SCRIPT := agent-git-setup.sh
TEST := agent-git-setup-test.sh
MINT := mint-token.sh

.PHONY: test lint ci

test:
	bash $(TEST)

lint:
	shellcheck $(SCRIPT) $(TEST) $(MINT)
	shfmt -d $(SCRIPT) $(TEST) $(MINT)

# Run everything CI runs, locally, before pushing.
ci: test lint
