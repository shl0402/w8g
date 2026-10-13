#!/bin/zsh
set -euo pipefail
cd -- "$(dirname -- "$0")"

if [[ ! -x .venv/bin/python ]]; then
	./setup.command
fi

export W8G_HOST="${W8G_HOST:-0.0.0.0}"
exec .venv/bin/python -B run.py "$@"
