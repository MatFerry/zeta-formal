.PHONY: lint test regress tables formal-lint

lint:
	./scripts/lint.sh

test:
	uv run pytest -m "not nightly"

regress:
	uv run pytest

tables:
	uv run python scripts/gen_tables.py

formal-lint:
	./scripts/formal_lint.sh
