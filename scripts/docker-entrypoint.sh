#!/usr/bin/env bash
# docker-entrypoint.sh — OpenClaw container entrypoint
#
# Handles two optional startup tasks before handing off to the main process:
#   1. Fix Homebrew ownership if a stale named volume overrides image permissions.
#   2. When PostgreSQL is installed (OPENCLAW_INSTALL_POSTGRESQL=1), initialize
#      and start the PostgreSQL service.
#
# Usage: Set as ENTRYPOINT in docker-compose or docker run. The CMD
# (e.g. "node openclaw.mjs gateway ...") is passed through unchanged.
#
# Environment variables:
#   OPENCLAW_PG_DB   — database name to create on first run (default: openclaw_qa)
#   OPENCLAW_PG_USER — database user to create (default: openclaw)
#   OPENCLAW_PG_PASS — database password (default: openclaw)
set -euo pipefail

# Fix Homebrew ownership if a stale named volume overrides image permissions.
if [ -d /home/linuxbrew/.linuxbrew ] && [ ! -w /home/linuxbrew/.linuxbrew/bin ]; then
  sudo chown -R node:node /home/linuxbrew/.linuxbrew
fi

PG_DB="${OPENCLAW_PG_DB:-openclaw_qa}"
PG_USER="${OPENCLAW_PG_USER:-openclaw}"
PG_PASS="${OPENCLAW_PG_PASS:-openclaw}"

if command -v pg_lsclusters >/dev/null 2>&1; then
  echo "[entrypoint] Starting PostgreSQL..."
  service postgresql start || true

  echo "[entrypoint] Waiting for PostgreSQL to be ready..."
  for i in $(seq 1 30); do
    if su postgres -c "pg_isready" >/dev/null 2>&1; then
      echo "[entrypoint] PostgreSQL ready."
      break
    fi
    sleep 1
  done

  echo "[entrypoint] Ensuring database '${PG_DB}' and user '${PG_USER}' exist..."
  su postgres -c "psql -tc \"SELECT 1 FROM pg_roles WHERE rolname='${PG_USER}'\" | grep -q 1 \
    || psql -c \"CREATE USER ${PG_USER} WITH PASSWORD '${PG_PASS}';\"" || true
  su postgres -c "psql -tc \"SELECT 1 FROM pg_database WHERE datname='${PG_DB}'\" | grep -q 1 \
    || psql -c \"CREATE DATABASE ${PG_DB} OWNER ${PG_USER};\"" || true

  echo "[entrypoint] PostgreSQL setup complete. DATABASE_URL=postgresql://${PG_USER}:${PG_PASS}@localhost:5432/${PG_DB}"
fi

exec "$@"
