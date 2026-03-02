FROM node:22-bookworm@sha256:cd7bcd2e7a1e6f72052feb023c7f6b722205d3fcab7bbcbd2d1bfdab10b1e935

# Install Bun (required for build scripts)
RUN curl -fsSL https://bun.sh/install | bash && \
    rm -rf /tmp/*
ENV PATH="/root/.bun/bin:${PATH}"

RUN corepack enable && corepack install -g pnpm
ENV COREPACK_ENABLE_AUTO_INSTALL=1

WORKDIR /app
RUN chown node:node /app

# Core skill dependencies (sudo, jq, ripgrep, tmux, ffmpeg, go, procps, build-essential)
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      sudo jq ripgrep tmux ffmpeg golang-go procps build-essential \
      ca-certificates curl gnupg && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/* /tmp/* /var/tmp/*

# Passwordless sudo for the node user
RUN echo 'node ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/node && \
    chmod 0440 /etc/sudoers.d/node

# Optional extra apt packages from user config
ARG OPENCLAW_DOCKER_APT_PACKAGES=""
RUN if [ -n "$OPENCLAW_DOCKER_APT_PACKAGES" ]; then \
      apt-get update && \
      DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $OPENCLAW_DOCKER_APT_PACKAGES && \
      apt-get clean && \
      rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*; \
    fi

COPY --chown=node:node package.json pnpm-lock.yaml pnpm-workspace.yaml .npmrc ./
COPY --chown=node:node ui/package.json ./ui/package.json
COPY --chown=node:node patches ./patches
COPY --chown=node:node scripts ./scripts

USER node
# Reduce OOM risk on low-memory hosts during dependency installation.
# Docker builds on small VMs may otherwise fail with "Killed" (exit 137).
RUN NODE_OPTIONS=--max-old-space-size=2048 pnpm install --frozen-lockfile && \
    pnpm store prune

# Optionally install Google Chrome and Chromium for browser automation.
# Build with: docker build --build-arg OPENCLAW_INSTALL_BROWSER=1 ...
# Adds ~500MB but eliminates the 60-90s Playwright install on every container start.
# Must run after pnpm install so playwright-core is available in node_modules.
USER root
ARG OPENCLAW_INSTALL_BROWSER="1"
RUN if [ -n "$OPENCLAW_INSTALL_BROWSER" ]; then \
      apt-get update && \
      DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends xvfb wget && \
      wget -q https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb && \
      dpkg -i google-chrome-stable_current_amd64.deb || true && \
      apt-get --fix-broken install -y && \
      rm -f google-chrome-stable_current_amd64.deb && \
      mkdir -p /home/node/.cache/ms-playwright && \
      npx playwright-core install-deps chromium && \
      mkdir -p /home/node/.cache/ms-playwright && \
      PLAYWRIGHT_BROWSERS_PATH=/home/node/.cache/ms-playwright \
      npx playwright-core install chromium && \
      chown -R node:node /home/node/.cache/ms-playwright && \
      apt-get clean && \
      rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*; \
    fi

# Optionally install Docker CLI for sandbox container management.
# Build with: docker build --build-arg OPENCLAW_INSTALL_DOCKER_CLI=1 ...
# Adds ~50MB. Only the CLI is installed — no Docker daemon.
# Required for agents.defaults.sandbox to function in Docker deployments.
ARG OPENCLAW_INSTALL_DOCKER_CLI=""
ARG OPENCLAW_DOCKER_GPG_FINGERPRINT="9DC858229FC7DD38854AE2D88D81803C0EBFCD88"
RUN if [ -n "$OPENCLAW_INSTALL_DOCKER_CLI" ]; then \
      apt-get update && \
      DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ca-certificates curl gnupg && \
      install -m 0755 -d /etc/apt/keyrings && \
      # Verify Docker apt signing key fingerprint before trusting it as a root key.
      # Update OPENCLAW_DOCKER_GPG_FINGERPRINT when Docker rotates release keys.
      curl -fsSL https://download.docker.com/linux/debian/gpg -o /tmp/docker.gpg.asc && \
      expected_fingerprint="$(printf '%s' "$OPENCLAW_DOCKER_GPG_FINGERPRINT" | tr '[:lower:]' '[:upper:]' | tr -d '[:space:]')" && \
      actual_fingerprint="$(gpg --batch --show-keys --with-colons /tmp/docker.gpg.asc | awk -F: '$1 == "fpr" { print toupper($10); exit }')" && \
      if [ -z "$actual_fingerprint" ] || [ "$actual_fingerprint" != "$expected_fingerprint" ]; then \
        echo "ERROR: Docker apt key fingerprint mismatch (expected $expected_fingerprint, got ${actual_fingerprint:-<empty>})" >&2; \
        exit 1; \
      fi && \
      gpg --dearmor -o /etc/apt/keyrings/docker.gpg /tmp/docker.gpg.asc && \
      rm -f /tmp/docker.gpg.asc && \
      chmod a+r /etc/apt/keyrings/docker.gpg && \
      printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian bookworm stable\n' \
        "$(dpkg --print-architecture)" > /etc/apt/sources.list.d/docker.list && \
      apt-get update && \
      DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        docker-ce-cli docker-compose-plugin && \
      apt-get clean && \
      rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*; \
    fi

USER node
COPY --chown=node:node . .
RUN pnpm build && \
    rm -rf /app/.cache
# Force pnpm for UI build (Bun may fail on ARM/Synology architectures)
ENV OPENCLAW_PREFER_PNPM=1
RUN pnpm ui:build && \
    rm -rf /app/ui/.cache /app/ui/node_modules/.cache

# Expose the CLI binary without requiring npm global writes as non-root.
USER root
RUN ln -sf /app/openclaw.mjs /usr/local/bin/openclaw \
 && chmod 755 /app/openclaw.mjs

ENV NODE_ENV=production

# Optionally install Homebrew (on by default).
# Build with: docker build --build-arg OPENCLAW_INSTALL_BREW=0 ... to skip.
USER root
ARG OPENCLAW_INSTALL_BREW="1"
RUN if [ "$OPENCLAW_INSTALL_BREW" = "1" ]; then \
      if ! id -u linuxbrew >/dev/null 2>&1; then useradd -m -s /bin/bash linuxbrew; fi; \
      mkdir -p /home/linuxbrew/.linuxbrew; \
      chown -R linuxbrew:linuxbrew /home/linuxbrew; \
      su - linuxbrew -c "NONINTERACTIVE=1 CI=1 /bin/bash -c '$( curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)'"; \
      if [ ! -e /home/linuxbrew/.linuxbrew/Library ]; then \
        ln -s /home/linuxbrew/.linuxbrew/Homebrew/Library /home/linuxbrew/.linuxbrew/Library; \
      fi; \
      if [ ! -x /home/linuxbrew/.linuxbrew/bin/brew ]; then echo "brew install failed"; exit 1; fi; \
      ln -sf /home/linuxbrew/.linuxbrew/bin/brew /usr/local/bin/brew; \
      chown -R node:node /home/linuxbrew/.linuxbrew; \
    fi
ENV HOMEBREW_PREFIX=/home/linuxbrew/.linuxbrew
ENV HOMEBREW_CELLAR=/home/linuxbrew/.linuxbrew/Cellar
ENV HOMEBREW_REPOSITORY=/home/linuxbrew/.linuxbrew/Homebrew
ENV GOPATH=/home/node/go
ENV PATH=/home/node/.npm-global/bin:/home/node/.local/bin:/home/node/go/bin:/home/linuxbrew/.linuxbrew/bin:/home/linuxbrew/.linuxbrew/sbin:${PATH}

# Global npm tools (installed to /home/node/.npm-global for node user access)
RUN npm install -g @bitwarden/cli caldav-cli @withgraphite/graphite-cli trash-cli

# yt-dlp via brew (must run as non-root)
RUN su -c '/home/linuxbrew/.linuxbrew/bin/brew install yt-dlp' node


# Security hardening: Run as non-root user
# The node:22-bookworm image includes a 'node' user (uid 1000)
# This reduces the attack surface by preventing container escape via root privileges
USER node

# Pre-install all skill dependencies (brew formulas, go modules, node/uv packages).
# Reads skills/*/SKILL.md metadata. Individual failures are non-fatal.
# Build with: docker build --build-arg OPENCLAW_INSTALL_SKILL_DEPS=0 ... to skip.
# Build with: docker build --build-arg OPENCLAW_SKIP_ML_DEPS=1 ... to skip heavy AI/ML packages (saves ~3GB).
ARG OPENCLAW_INSTALL_SKILL_DEPS="1"
ARG OPENCLAW_SKIP_ML_DEPS="0"
RUN if [ "$OPENCLAW_INSTALL_SKILL_DEPS" = "1" ]; then \
      OPENCLAW_SKIP_ML_DEPS=$OPENCLAW_SKIP_ML_DEPS node scripts/install-skills-deps.mjs; \
      if [ -x /home/linuxbrew/.linuxbrew/bin/brew ]; then \
        /home/linuxbrew/.linuxbrew/bin/brew cleanup --prune=all -s; \
        rm -rf /home/linuxbrew/.linuxbrew/Library/Homebrew/vendor/bundle/ruby; \
        rm -rf /home/linuxbrew/.linuxbrew/Library/Taps/homebrew/homebrew-*/.*; \
        rm -rf /home/linuxbrew/.linuxbrew/var/homebrew/locks; \
        rm -rf /home/linuxbrew/.linuxbrew/Caskroom; \
        find /home/linuxbrew/.linuxbrew/Cellar -name 'doc' -type d -exec rm -rf {} + 2>/dev/null || true; \
        find /home/linuxbrew/.linuxbrew/Cellar -name 'man' -type d -exec rm -rf {} + 2>/dev/null || true; \
        find /home/linuxbrew/.linuxbrew/Cellar -name 'info' -type d -exec rm -rf {} + 2>/dev/null || true; \
      fi; \
      npm cache clean --force 2>/dev/null || true; \
      rm -rf /home/node/.cache /home/node/.npm; \
      sudo find /tmp -mindepth 1 -delete 2>/dev/null || true; \
      sudo find /var/tmp -mindepth 1 -delete 2>/dev/null || true; \
    fi

# Fix brew volume ownership at startup (handles stale named volumes).
ENTRYPOINT ["scripts/docker-entrypoint.sh"]

# Start gateway server with default config.
# Binds to loopback (127.0.0.1) by default for security.
#
# For container platforms requiring external health checks:
#   1. Set OPENCLAW_GATEWAY_TOKEN or OPENCLAW_GATEWAY_PASSWORD env var
#   2. Override CMD: ["node","openclaw.mjs","gateway","--allow-unconfigured","--bind","lan"]
CMD ["node", "openclaw.mjs", "gateway", "--allow-unconfigured"]
