#!/usr/bin/env python3
import os
from pathlib import Path

# Tiny .env loader; no secrets are placed in public/.
p = Path(__file__).parent / ".env"
if p.exists():
	for line in p.read_text().splitlines():
		if "=" in line and not line.lstrip().startswith("#"):
			k, v = line.split("=", 1)
			os.environ.setdefault(k.strip(), v.strip().strip('"').strip("'"))
from server.app import main

main()
