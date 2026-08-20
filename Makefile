SCRIPT := agent-git-setup.sh
TEST := agent-git-setup-test.sh

.PHONY: test lint ci

test:
	bash $(TEST)

lint:
	shellcheck $(SCRIPT) $(TEST)
	shfmt -d $(SCRIPT) $(TEST)

# Run everything CI runs, locally, before pushing.
ci: test lint
