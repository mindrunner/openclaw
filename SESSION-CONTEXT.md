# OpenClaw Docker Improvements — Session Context

**Date:** 2026-02-20
**Branch:** `main` (local is 69 commits behind `origin/main`)
**Status:** Uncommitted changes, not yet staged or committed

## What Was Done

Overhauled the Docker setup for OpenClaw to make the container self-contained with all skill dependencies pre-installed. The changes span 5 files (3 modified, 2 new).

### Summary of Changes

#### 1. `Dockerfile` — Major additions
- **Core apt packages:** Added `sudo`, `jq`, `ripgrep`, `tmux`, `ffmpeg`, `golang-go`, `procps`, `build-essential` as base layer.
- **Passwordless sudo** for the `node` user (needed by some skills at runtime).
- **Homebrew (Linuxbrew):** Installed as the `linuxbrew` user, then ownership given to `node`. Controlled by build arg `OPENCLAW_INSTALL_BREW` (default `"1"`).
- **Skill dependency auto-install:** Runs `scripts/install-skills-deps.mjs` at build time to parse `skills/*/SKILL.md` metadata and install brew formulas, Go modules, node packages, and uv packages. Controlled by build arg `OPENCLAW_INSTALL_SKILL_DEPS` (default `"1"`).
- **Entrypoint:** Set to `scripts/docker-entrypoint.sh` to fix brew volume ownership at startup.
- **PATH/env vars:** Added `GOPATH`, `HOMEBREW_*`, and extended `PATH` for brew, go, and user-local bins.
- Forced `corepack install -g pnpm` and set `COREPACK_ENABLE_AUTO_INSTALL=1`.

#### 2. `docker-compose.yml` — Networking & volumes
- Added a named volume `openclaw-brew` for `/home/linuxbrew/.linuxbrew` (persists brew cache across container recreates).
- Switched both `openclaw-gateway` and `openclaw-cli` services from port-mapping to `network_mode: "host"`.
- Mounted the brew volume in both services.
- Changed `openclaw-cli` entrypoint to go through `docker-entrypoint.sh`.

#### 3. `docker-setup.sh` — Build script fixes
- Sources existing `.env` file at startup so previous settings (like `OPENCLAW_DOCKER_APT_PACKAGES`) are preserved across re-runs.
- Passes new build args `OPENCLAW_INSTALL_BREW` and `OPENCLAW_INSTALL_SKILL_DEPS` to `docker build`.
- Fixed `.env` value quoting: changed `%s=%s` to `%s="%s"` in `upsert_env` function so values with spaces/special chars are properly quoted.

#### 4. `scripts/docker-entrypoint.sh` (NEW)
- Simple shell script that fixes Homebrew directory ownership if a stale named volume overrides image permissions, then `exec "$@"`.

#### 5. `scripts/install-skills-deps.mjs` (NEW)
- Node.js script that:
  - Scans `skills/*/SKILL.md` for YAML frontmatter metadata
  - Extracts install specs (brew formulas, go modules, node packages, uv packages)
  - Skips platform-restricted or cask-only items
  - Installs everything, treating brew failures as warnings (platform incompatibility) and all others as fatal
  - Uses brew's Go instead of Debian's ancient version for `go install`

## What Remains / Next Steps

1. **`git pull`** — Local branch is 69 commits behind origin. Pull before committing to avoid conflicts.
2. **Test the Docker build** — Run `./docker-setup.sh` or `docker build .` to verify everything builds cleanly.
3. **Test skill deps** — Verify that skills requiring brew/go/node packages work inside the container.
4. **Commit** — All 5 files need to be staged and committed. Suggested commit message:
   ```
   Docker: pre-install skill deps, add Homebrew, switch to host networking
   ```
5. **Consider:** Whether `network_mode: "host"` is appropriate for all deployment targets (it removes network isolation but simplifies port handling).

## File List

| File | Status |
|---|---|
| `Dockerfile` | Modified |
| `docker-compose.yml` | Modified |
| `docker-setup.sh` | Modified |
| `scripts/docker-entrypoint.sh` | New (untracked) |
| `scripts/install-skills-deps.mjs` | New (untracked) |

## How to Resume

```bash
cd /path/to/openclaw
git status                    # Verify same uncommitted state
cat SESSION-CONTEXT.md        # Read this file
# Continue with testing/committing the Docker changes
```
