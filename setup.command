#!/bin/zsh
set -euo pipefail
cd -- "$(dirname -- "$0")"

if [[ ! -x .venv/bin/python ]]; then
	python3 -m venv .venv
fi

.venv/bin/python -m pip install -r requirements-lock.txt
print "Setup complete. Start the server from this folder with:"
print "W8G_HOST=0.0.0.0 .venv/bin/python -B run.py"
