#!/usr/bin/env bash
# Run the gateway test suite (stdlib unittest — no install needed).
cd "$(dirname "$0")"
exec python3 -m unittest discover -s tests -v
