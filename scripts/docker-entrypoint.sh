#!/bin/sh
# Fix Homebrew ownership if a stale named volume overrides image permissions.
if [ -d /home/linuxbrew/.linuxbrew ] && [ ! -w /home/linuxbrew/.linuxbrew/bin ]; then
  sudo chown -R node:node /home/linuxbrew/.linuxbrew
fi
exec "$@"
