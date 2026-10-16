# nebula-manager - developer tasks
.PHONY: test lint help

help:
	@echo "Targets:"
	@echo "  make test   Run the test suite (./run_tests.sh)"
	@echo "  make lint   Syntax-check the entrypoint and all modules"

test:
	@./run_tests.sh

lint:
	@bash -n nebula-manager
	@for f in lib/*.sh tests/*.sh run_tests.sh nebula-manager.sh; do bash -n "$$f" || exit 1; done
	@if shellcheck --version >/dev/null 2>&1; then \
		echo "running shellcheck..."; \
		shellcheck -x -S warning nebula-manager lib/*.sh || true; \
	 else \
		echo "shellcheck unavailable (skipping)"; \
	 fi
	@echo "syntax OK"
