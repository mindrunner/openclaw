#!/usr/bin/env bash
# docker-entrypoint.sh — OpenClaw container entrypoint
#
# Handles one optional startup task before handing off to the main process:
#   Fix Homebrew ownership if a stale named volume overrides image permissions.
#
# PostgreSQL is provided as a separate service (openclaw-postgres) in docker-compose.
# Use the DATABASE_URL or OPENCLAW_PG_* env vars to connect.
set -euo pipefail

# Fix Homebrew ownership if a stale named volume overrides image permissions.
if [ -d /home/linuxbrew/.linuxbrew ] && [ ! -w /home/linuxbrew/.linuxbrew/bin ]; then
  sudo chown -R node:node /home/linuxbrew/.linuxbrew
fi

exec "$@"
