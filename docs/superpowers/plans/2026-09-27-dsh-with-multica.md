# dsh-with-multica Runtime Image Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a Docker runtime image that registers `dsh` as a multica coding-agent runtime, with an env-driven OpenAI-compatible LLM provider, and a GitHub release flow that publishes per-arch tarballs on `v*` tags.

**Architecture:** 4-stage Dockerfile (multica downloader / bridge-bundle source clone / dsh + profile install / final slim image). Entrypoint drops root→agent, validates config + LLM env vars, execs `multica daemon start`. CI mirrors `agents-with-multica` on push (per-arch GHCR push) and `v*` tags (GitHub Release with `docker save | gzip` tarballs).

**Tech Stack:** Docker multi-stage build, GitHub Actions, GHCR, multica CLI, `@deepseek-ai/dsh` (npm), `@multica-ai/dsh-runtime` (built from source), bash entrypoint.

**Spec:** `docs/superpowers/specs/2026-09-27-dsh-with-multica-design.md`

**Reference:** `~/code/agents-with-multica/base/` — only the `base/` subdirectory is to be used as a structural reference; do not copy cc-proxy / opencode / sudo / claude-specific bits.

---

## File Structure

```
dsh-with-multica/
├── versions.yaml                                 # Pinned versions, single source of truth
├── base/
│   ├── Dockerfile                                 # 4-stage multi-stage build
│   ├── entrypoint.sh                             # root→agent drop, multica daemon start
│   └── cordis.patch.yml                           # env-driven LLM provider overlay
│                                                  #   (written into profile at build time)
└── .github/
    └── workflows/
        └── build.yml                              # GHCR push on main, GH Release on v*
```

Files NOT in scope (per spec's YAGNI section):
- No derived `code-writer/ts` or `code-writer/py` variants
- No multi-arch manifest (per-arch tags only, matching reference)
- No automated test suite
- No cc-proxy, no sudo, no claude/opencode configs

---

## Task 1: versions.yaml

**Files:**
- Create: `versions.yaml`

- [ ] **Step 1: Write `versions.yaml`**

```yaml
project:
  version: "0.1.0"
dsh:
  version: "0.1.7-rc.2"
multica:
  version: "0.5.3"
  repo: "multica-ai/multica"
dsh_multica_runtime:
  repo: "multica-ai/dsh-multica-runtime"
  commit: "e29aae228449dfe50e88af60ef4281e38ca44e2a"
```

- [ ] **Step 2: Verify file parses as valid YAML**

Run: `python3 -c "import yaml; print(yaml.safe_load(open('versions.yaml')))"`
Expected: a dict like `{'project': {'version': '0.1.0'}, 'dsh': {'version': '0.1.7-rc.2'}, 'multica': {'version': '0.5.3', 'repo': 'multica-ai/multica'}, 'dsh_multica_runtime': {'repo': 'multica-ai/dsh-multica-runtime', 'commit': 'e29aae228449dfe50e88af60ef4281e38ca44e2a'}}`

- [ ] **Step 3: Commit**

```bash
git add versions.yaml
git commit -m "feat: add versions.yaml as single source of truth for pinned versions"
```

---

## Task 2: base/cordis.patch.yml — env-driven LLM provider overlay

**Files:**
- Create: `base/cordis.patch.yml`

This file is COPYed into the image at build time and written into `~/.dsh/profiles/multica/cordis.patch.yml` (overwriting the empty `[]` template that `dsh plugin add` creates). It activates the `llm-pi-ai` provider route from env vars and disables the unused DeepSeek-native route.

- [ ] **Step 1: Write `base/cordis.patch.yml`**

```yaml
# Operator-supplied OpenAI-compatible endpoint. All values resolve from env at
# profile load time; nothing here is a secret. Set OPENAI_BASE_URL /
# OPENAI_API_KEY / OPENAI_MODEL via the multica dashboard custom_env or
# `docker run -e`.
- id: llm-pi-ai
  config:
    providers:
      openai:
        api: openai-completions
        baseURL: !!js process.env.OPENAI_BASE_URL
        apiKeyEnv: OPENAI_API_KEY
        displayName: !!js process.env.OPENAI_PROVIDER_NAME || 'OpenAI'
        models:
          - id: !!js process.env.OPENAI_MODEL || 'gpt-4o'
            name: !!js process.env.OPENAI_MODEL_NAME || process.env.OPENAI_MODEL || 'gpt-4o'
            contextWindow: !!js Number(process.env.OPENAI_CONTEXT_WINDOW ?? 128000)
            maxTokens: !!js Number(process.env.OPENAI_MAX_TOKENS ?? 16384)

# Disable DeepSeek's own API-key provider route so a missing DEEPSEEK_API_KEY
# doesn't trip the daemon's probe with an unrelated credential error. This
# image is provider-agnostic and only uses the OpenAI-compatible route above.
# (Patch row id is `llm-deepseek`; the package name is
# `@deepseek-ai/dsh-llm-deepseek-api-key`. Patch composition targets row ids,
# not package names.)
- id: llm-deepseek
  disabled: true
```

- [ ] **Step 2: Verify the file parses as valid YAML**

Run: `python3 -c "import yaml; print(yaml.safe_load(open('base/cordis.patch.yml')))"`
Expected: a list of two dicts, each with an `id` key.

Note: `!!js` tags are dsh-specific YAML extensions; Python's `yaml.safe_load` will choke on them. If the parse fails specifically on the `!!js` tags with `could not determine a constructor for the tag 'tag:yaml.org,2002:js'`, that's expected — the file is valid YAML to dsh's loader but not to plain PyYAML. Confirm visually that the structure is a list of two dicts and move on.

- [ ] **Step 3: Commit**

```bash
git add base/cordis.patch.yml
git commit -m "feat: add cordis.patch.yml with env-driven OpenAI provider overlay"
```

---

## Task 3: base/entrypoint.sh

**Files:**
- Create: `base/entrypoint.sh`

Two-phase script: root phase sets up dirs/credentials and re-execs as `agent`; agent phase validates config + LLM env vars and execs `multica daemon start`.

- [ ] **Step 1: Write `base/entrypoint.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail

# Root phase: create directories, write git credentials, fix ownership, then
# re-exec as the unprivileged agent user.
if [ "$(id -u)" = "0" ]; then
  mkdir -p /etc/multica /home/agent/.multica /home/agent/.dsh /home/agent/wiki

  # Optional git credentials: GIT_TOKEN, GIT_USERNAME (default oauth2),
  # GIT_HOST (required when GIT_TOKEN is set).
  if [ -n "${GIT_TOKEN:-}" ]; then
    if [ -z "${GIT_HOST:-}" ]; then
      echo "entrypoint: GIT_TOKEN is set but GIT_HOST is empty; set GIT_HOST to the git host (e.g. github.com)" >&2
      exit 1
    fi
    GIT_USERNAME="${GIT_USERNAME:-oauth2}"
    printf 'https://%s:%s@%s\n' "${GIT_USERNAME}" "${GIT_TOKEN}" "${GIT_HOST}" > /home/agent/.git-credentials
    chmod 600 /home/agent/.git-credentials
  fi

  chown -R agent:agent /home/agent

  # Re-exec as agent, preserving the environment (-p) so MULTICA_* and OPENAI_*
  # vars survive the drop.
  exec su -p -s /bin/bash agent -c "HOME=/home/agent exec $0"
fi

# Agent phase: running as the agent user.
set -x  # surface each step in container logs for debugging

# 1. multica daemon config — operator must mount this read-only.
if [ ! -f /etc/multica/config.json ]; then
  echo "entrypoint: /etc/multica/config.json is missing; mount the multica daemon config read-only at /etc/multica/config.json" >&2
  exit 1
fi
cp /etc/multica/config.json /home/agent/.multica/config.json

# 2. LLM env vars — validate before starting the daemon so a missing var
#    surfaces here with a clear message instead of as a misleading
#    "runtime missing" probe failure inside the daemon.
for var in OPENAI_BASE_URL OPENAI_API_KEY OPENAI_MODEL; do
  if [ -z "${!var:-}" ]; then
    echo "entrypoint: ${var} is not set; set it via the multica dashboard custom_env or 'docker run -e'" >&2
    exit 1
  fi
done

# 3. Start the multica daemon in the foreground. It probes dsh
#    (--profile multica --probe), registers it as a runtime, and keeps the
#    container alive.
RUNTIME_NAME="${MULTICA_AGENT_RUNTIME_NAME:-Docker}"
DEVICE_NAME="${MULTICA_DAEMON_DEVICE_NAME:-Docker}"
exec multica daemon start --runtime-name "${RUNTIME_NAME}" --device-name "${DEVICE_NAME}"
```

- [ ] **Step 2: Make it executable**

Run: `chmod +x base/entrypoint.sh`
Expected: no output; `ls -l base/entrypoint.sh` shows `-rwxr-xr-x ...`.

- [ ] **Step 3: Verify the script parses**

Run: `bash -n base/entrypoint.sh`
Expected: no output, exit 0 (syntax check passes).

- [ ] **Step 4: Commit**

```bash
git add base/entrypoint.sh
git commit -m "feat: add entrypoint.sh with root→agent drop and env validation"
```

---

## Task 4: base/Dockerfile — 4-stage build

**Files:**
- Create: `base/Dockerfile`

Stage 1 downloads the multica CLI from GitHub releases. Stage 2 clones the bridge bundle repo at a pinned commit. Stage 3 installs dsh + pnpm, creates the agent user, runs `dsh plugin --profile multica add` to install the bridge bundle and create the multica profile, then writes our `cordis.patch.yml` overlay into the profile directory. Stage 4 is the slim final image.

- [ ] **Step 1: Write `base/Dockerfile`**

```dockerfile
# syntax=docker/dockerfile:1.7

# ---------- Stage 1: multica CLI downloader ----------
FROM alpine:3.20 AS multica-downloader
ARG MULTICA_VERSION
ARG TARGETARCH
RUN case "${TARGETARCH}" in \
      amd64) ARCH=x86_64  ;; \
      arm64) ARCH=aarch64 ;; \
      *) echo "unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac && \
    wget -q -O /tmp/multica.tar.gz \
      "https://github.com/multica-ai/multica/releases/download/v${MULTICA_VERSION}/multica-cli-${MULTICA_VERSION}-linux-${ARCH}.tar.gz" && \
    mkdir -p /out && \
    tar -xzf /tmp/multica.tar.gz -C /out && \
    test -x /out/multica

# ---------- Stage 2: bridge bundle source ----------
FROM alpine:3.20 AS bundle-source
ARG DSH_MULTICA_RUNTIME_REPO
ARG DSH_MULTICA_RUNTIME_COMMIT
RUN apk add --no-cache git && \
    git clone --filter=blob:none "${DSH_MULTICA_RUNTIME_REPO}" /out/dsh-multica-runtime && \
    git -C /out/dsh-multica-runtime checkout "${DSH_MULTICA_RUNTIME_COMMIT}" && \
    test -f /out/dsh-multica-runtime/package.json && \
    test -f /out/dsh-multica-runtime/cordis.patch.yml

# ---------- Stage 3: dsh + multica profile install ----------
FROM node:22-bookworm-slim AS dsh-profile-install
ARG DSH_VERSION
# pnpm is required by `dsh plugin`; install it alongside dsh.
RUN npm install -g "@deepseek-ai/dsh@${DSH_VERSION}" pnpm
# Create the agent user with a fixed UID so ownership matches stage 4.
RUN useradd --uid 1000 --create-home --shell /bin/bash agent
ENV HOME=/home/agent \
    DSH_HOME=/home/agent/.dsh
# Bring in the bridge bundle source and install it into the multica profile.
# `dsh plugin --profile multica add` auto-adds @deepseek-ai/dsh-base (the
# DEFAULT_PROFILE_BUNDLES) and the bridge bundle, creating the profile
# directory and its package.json.
COPY --from=bundle-source /out/dsh-multica-runtime /dsh-multica-runtime
RUN dsh plugin --profile multica add /dsh-multica-runtime && \
    test -f /home/agent/.dsh/profiles/multica/package.json
# Overwrite the empty [] template the profile init created with our
# env-driven LLM provider overlay.
COPY base/cordis.patch.yml /home/agent/.dsh/profiles/multica/cordis.patch.yml

# ---------- Stage 4: final image ----------
FROM node:22-bookworm-slim AS final
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      git ca-certificates curl openssh-client && \
    rm -rf /var/lib/apt/lists/*
RUN useradd --uid 1000 --create-home --shell /bin/bash agent
# multica CLI from stage 1.
COPY --from=multica-downloader /out/multica /usr/local/bin/multica
# dsh + its global node_modules from stage 3. The npm global layout puts the
# dsh binary at /usr/local/bin/dsh (a symlink into node_modules) and the
# packages at /usr/local/lib/node_modules.
COPY --from=dsh-profile-install /usr/local/bin/dsh /usr/local/bin/dsh
COPY --from=dsh-profile-install /usr/local/lib/node_modules /usr/local/lib/node_modules
# Pre-built multica profile (including our cordis.patch.yml overlay).
COPY --from=dsh-profile-install --chown=agent:agent /home/agent/.dsh /home/agent/.dsh
# Entrypoint.
COPY --chmod=0755 base/entrypoint.sh /entrypoint.sh
# Runtime dirs.
RUN mkdir -p /home/agent/wiki && chown -R agent:agent /home/agent
# System-level git config: credential store + identity.
RUN git config --system credential.helper store && \
    git config --system user.name agent && \
    git config --system user.email agent@container
USER agent
WORKDIR /home/agent
ENTRYPOINT ["/entrypoint.sh"]
```

- [ ] **Step 2: Smoke-test the Dockerfile parses (no build yet)**

Run: `docker build --check -f base/Dockerfile . 2>&1 | tail -20` (if Docker's `--check` is available) or skip to the next step. If `--check` is not supported by your Docker version, skip this step.

- [ ] **Step 3: Commit**

```bash
git add base/Dockerfile
git commit -m "feat: add 4-stage Dockerfile for dsh-with-multica runtime image"
```

---

## Task 5: Local smoke build

**Files:**
- None (verification only)

This task confirms the Dockerfile builds end-to-end on the local machine before wiring up CI. It catches ARG typos, missing COPY sources, and `dsh plugin add` failures early. Build time is expected to be several minutes (network-bound: npm install + git clone + pnpm install).

- [ ] **Step 1: Extract versions from versions.yaml into shell vars**

Run:
```bash
eval "$(python3 -c "
import yaml
d = yaml.safe_load(open('versions.yaml'))
print(f'MULTICA_VERSION={d[\"multica\"][\"version\"]}')
print(f'DSH_VERSION={d[\"dsh\"][\"version\"]}')
print(f'DSH_MULTICA_RUNTIME_REPO={d[\"dsh_multica_runtime\"][\"repo\"]}')
print(f'DSH_MULTICA_RUNTIME_COMMIT={d[\"dsh_multica_runtime\"][\"commit\"]}')
")"
echo "MULTICA_VERSION=$MULTICA_VERSION DSH_VERSION=$DSH_VERSION DSH_MULTICA_RUNTIME_REPO=$DSH_MULTICA_RUNTIME_REPO DSH_MULTICA_RUNTIME_COMMIT=$DSH_MULTICA_RUNTIME_COMMIT"
```
Expected: `MULTICA_VERSION=0.5.3 DSH_VERSION=0.1.7-rc.2 DSH_MULTICA_RUNTIME_REPO=multica-ai/dsh-multica-runtime DSH_MULTICA_RUNTIME_COMMIT=e29aae228449dfe50e88af60ef4281e38ca44e2a`

- [ ] **Step 2: Build the image for the local arch**

Run:
```bash
docker build \
  --build-arg MULTICA_VERSION="$MULTICA_VERSION" \
  --build-arg DSH_VERSION="$DSH_VERSION" \
  --build-arg DSH_MULTICA_RUNTIME_REPO="https://github.com/${DSH_MULTICA_RUNTIME_REPO}.git" \
  --build-arg DSH_MULTICA_RUNTIME_COMMIT="$DSH_MULTICA_RUNTIME_COMMIT" \
  -t dsh-with-multica:smoke \
  -f base/Dockerfile .
```
Expected: build completes with `Successfully tagged dsh-with-multica:smoke`. If Stage 3 fails with an incompatible-plugin diagnostic from `dsh plugin`, see the spec's "peerDependency compatibility" section — bump `dsh_multica_runtime.commit` to a newer main HEAD; only fall back to `dsh plugin allow-version` after explicit verification.

- [ ] **Step 3: Verify the binaries are on PATH inside the image**

Run: `docker run --rm dsh-with-multica:smoke sh -c 'command -v dsh && command -v multica && dsh --version && multica --version'`
Expected: both `command -v` lines print absolute paths (`/usr/local/bin/dsh`, `/usr/local/bin/multica`), and both `--version` calls print their version strings.

- [ ] **Step 4: Verify the multica profile was installed**

Run: `docker run --rm dsh-with-multica:smoke sh -c 'test -f /home/agent/.dsh/profiles/multica/package.json && echo profile-ok && head -20 /home/agent/.dsh/profiles/multica/cordis.patch.yml'`
Expected: `profile-ok` printed, followed by the first 20 lines of our `cordis.patch.yml` overlay (starting with `# Operator-supplied OpenAI-compatible endpoint.`).

- [ ] **Step 5: Verify entrypoint env-var validation fires**

Run: `docker run --rm dsh-with-multica:smoke 2>&1 | head -20`
Expected: container exits non-zero with a message starting `entrypoint: /etc/multica/config.json is missing;` (because we didn't mount the config). This confirms the validation in the agent phase runs.

- [ ] **Step 6: Verify LLM env-var validation fires when config IS mounted**

Run:
```bash
echo '{"server_url":"ws://localhost:8080/ws","workspace_id":"00000000-0000-0000-0000-000000000000","token":"dummy"}' > /tmp/multica-config.json
docker run --rm \
  -v /tmp/multica-config.json:/etc/multica/config.json:ro \
  dsh-with-multica:smoke 2>&1 | head -5
```
Expected: container exits non-zero with a message like `entrypoint: OPENAI_BASE_URL is not set; set it via the multica dashboard custom_env or 'docker run -e'`.

- [ ] **Step 7: Commit any fixes discovered during the smoke build**

If the smoke build surfaced Dockerfile/entrypoint fixes, commit them:
```bash
git add -A
git commit -m "fix: address smoke-build findings"
```
If no fixes were needed, skip this step.

---

## Task 6: .github/workflows/build.yml — CI and release

**Files:**
- Create: `.github/workflows/build.yml`

Two jobs: `build` (runs on push to main and on PRs; builds per-arch images, pushes to GHCR only on push events) and `release` (runs only on `v*` tags; pulls per-arch images from GHCR, exports as tar.gz, creates a GitHub Release).

The workflow reads versions from `versions.yaml` with inline Python, the same pattern as the reference project.

- [ ] **Step 1: Write `.github/workflows/build.yml`**

```yaml
name: Build and release dsh-with-multica image

on:
  push:
    branches: [main]
    paths:
      - 'base/**'
      - 'versions.yaml'
      - '.github/workflows/build.yml'
    tags:
      - 'v*'
  pull_request:
    paths:
      - 'base/**'
      - 'versions.yaml'
      - '.github/workflows/build.yml'

env:
  REGISTRY: ghcr.io
  IMAGE_NAME: ${{ github.repository }}

jobs:
  build:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Set up QEMU
        uses: docker/setup-qemu-action@v3

      - name: Set up Buildx
        uses: docker/setup-buildx-action@v3

      - name: Log in to GHCR
        if: github.event_name == 'push'
        uses: docker/login-action@v3
        with:
          registry: ${{ env.REGISTRY }}
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Read versions from versions.yaml
        id: versions
        run: |
          python3 - <<'PY'
          import json, yaml
          d = yaml.safe_load(open('versions.yaml'))
          print(f"::set-output name=project_version::{d['project']['version']}")
          print(f"::set-output name=multica_version::{d['multica']['version']}")
          print(f"::set-output name=dsh_version::{d['dsh']['version']}")
          print(f"::set-output name=dsh_multica_runtime_repo::{d['dsh_multica_runtime']['repo']}")
          print(f"::set-output name=dsh_multica_runtime_commit::{d['dsh_multica_runtime']['commit']}")
          PY

      - name: Build and push (amd64)
        uses: docker/build-push-action@v6
        with:
          context: .
          file: base/Dockerfile
          platforms: linux/amd64
          push: ${{ github.event_name == 'push' }}
          tags: |
            ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}:latest-amd64
            ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}:${{ steps.versions.outputs.project_version }}-amd64
          build-args: |
            MULTICA_VERSION=${{ steps.versions.outputs.multica_version }}
            DSH_VERSION=${{ steps.versions.outputs.dsh_version }}
            DSH_MULTICA_RUNTIME_REPO=https://github.com/${{ steps.versions.outputs.dsh_multica_runtime_repo }}.git
            DSH_MULTICA_RUNTIME_COMMIT=${{ steps.versions.outputs.dsh_multica_runtime_commit }}

      - name: Build and push (arm64)
        uses: docker/build-push-action@v6
        with:
          context: .
          file: base/Dockerfile
          platforms: linux/arm64
          push: ${{ github.event_name == 'push' }}
          tags: |
            ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}:latest-arm64
            ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}:${{ steps.versions.outputs.project_version }}-arm64
          build-args: |
            MULTICA_VERSION=${{ steps.versions.outputs.multica_version }}
            DSH_VERSION=${{ steps.versions.outputs.dsh_version }}
            DSH_MULTICA_RUNTIME_REPO=https://github.com/${{ steps.versions.outputs.dsh_multica_runtime_repo }}.git
            DSH_MULTICA_RUNTIME_COMMIT=${{ steps.versions.outputs.dsh_multica_runtime_commit }}

  release:
    needs: build
    if: startsWith(github.ref, 'refs/tags/v')
    runs-on: ubuntu-latest
    permissions:
      contents: write
      packages: read
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Read versions from versions.yaml
        id: versions
        run: |
          python3 - <<'PY'
          import yaml
          d = yaml.safe_load(open('versions.yaml'))
          print(f"::set-output name=project_version::{d['project']['version']}")
          PY

      - name: Extract tag version
        id: tag
        run: echo "::set-output name=version::${GITHUB_REF#refs/tags/v}"

      - name: Log in to GHCR
        uses: docker/login-action@v3
        with:
          registry: ${{ env.REGISTRY }}
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Pull images and export as tar.gz
        run: |
          VERSION="${{ steps.versions.outputs.project_version }}"
          docker pull ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}:${VERSION}-amd64
          docker pull ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}:${VERSION}-arm64
          mkdir -p artifacts
          docker save ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}:${VERSION}-amd64 | gzip > artifacts/dsh-with-multica-${VERSION}-amd64.tar.gz
          docker save ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}:${VERSION}-arm64 | gzip > artifacts/dsh-with-multica-${VERSION}-arm64.tar.gz

      - name: Create GitHub Release
        uses: softprops/action-gh-release@v2
        with:
          name: ${{ steps.tag.outputs.version }}
          files: |
            artifacts/dsh-with-multica-${{ steps.versions.outputs.project_version }}-amd64.tar.gz
            artifacts/dsh-with-multica-${{ steps.versions.outputs.project_version }}-arm64.tar.gz
```

- [ ] **Step 2: Verify the workflow file parses as valid YAML**

Run: `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/build.yml')); print('yaml-ok')"`
Expected: `yaml-ok`

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/build.yml
git commit -m "ci: add build.yml with per-arch GHCR push and GitHub release flow"
```

---

## Task 7: README

**Files:**
- Create: `README.md`

Operator-facing documentation: what this image is, how to build locally, how to run it, what env vars and mounts it expects, and how to bump versions.

- [ ] **Step 1: Write `README.md`**

```markdown
# dsh-with-multica

A Docker runtime image that registers [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) (`dsh`) as a coding-agent runtime under a [Multica](https://github.com/multica-ai/multica) daemon.

This image mirrors the structure of the sibling project [`agents-with-multica`](https://github.com/multica-ai/agents-with-multica) (its `base/` image), substituting `dsh` for `claude+opencode` and dropping the cc-proxy LLM relay. `dsh` calls a third-party OpenAI-compatible endpoint directly; the endpoint URL, API key, and model ID are supplied at runtime via environment variables.

## What's in the image

- The `multica` CLI (downloaded from GitHub releases)
- `dsh` and its global node_modules (installed via npm)
- A pre-built `multica` profile under `/home/agent/.dsh/profiles/multica/` containing:
  - The `@deepseek-ai/dsh-base` bundle (core agent loop, LLM providers, session persistence)
  - The `@multica-ai/dsh-runtime` bridge bundle (Multica stdio protocol surface)
  - An env-driven `cordis.patch.yml` overlay that activates an `llm-pi-ai` provider route from `OPENAI_*` env vars and disables the unused `llm-deepseek` route

## Required runtime configuration

### Environment variables

| Variable | Required | Purpose |
|---|---|---|
| `OPENAI_BASE_URL` | yes | Third-party OpenAI-compatible endpoint URL |
| `OPENAI_API_KEY` | yes | The literal env-var name `OPENAI_API_KEY`; dsh resolves the actual secret value per request through its credential-ref system |
| `OPENAI_MODEL` | yes | Model ID to dispatch (multica sends `Model: {Provider: "openai", ID: <OPENAI_MODEL>}` on each execute) |
| `OPENAI_PROVIDER_NAME` | no | Display name in dsh model picker (default `OpenAI`) |
| `OPENAI_MODEL_NAME` | no | Display name for the model (default falls back to `OPENAI_MODEL`) |
| `OPENAI_CONTEXT_WINDOW` | no | Context window in tokens (default `128000`) |
| `OPENAI_MAX_TOKENS` | no | Max output tokens (default `16384`) |
| `MULTICA_AGENT_RUNTIME_NAME` | no | Display name in multica dashboard (default `Docker`) |
| `MULTICA_DAEMON_DEVICE_NAME` | no | Device identifier in multica (default `Docker`) |
| `GIT_TOKEN` | no | Git push credential |
| `GIT_USERNAME` | no | Git credential username (default `oauth2`; used with `GIT_TOKEN`) |
| `GIT_HOST` | no | Git credential host (required when `GIT_TOKEN` is set) |

### Volume mounts

| Mount | Required | Purpose |
|---|---|---|
| `/etc/multica/config.json` (read-only) | yes | multica daemon config: server URL, workspace ID, token |
| `/home/agent/wiki` (read-only) | no | Reference docs the agent can read |

The `agent` user inside the image is UID 1000. Operator-supplied bind mounts must be owned by UID 1000 (or world-readable, depending on your security posture).

## Building locally

Versions are pinned in `versions.yaml` (the single source of truth). To build:

```bash
eval "$(python3 -c "
import yaml
d = yaml.safe_load(open('versions.yaml'))
print(f'MULTICA_VERSION={d[\"multica\"][\"version\"]}')
print(f'DSH_VERSION={d[\"dsh\"][\"version\"]}')
print(f'DSH_MULTICA_RUNTIME_REPO={d[\"dsh_multica_runtime\"][\"repo\"]}')
print(f'DSH_MULTICA_RUNTIME_COMMIT={d[\"dsh_multica_runtime\"][\"commit\"]}')
")"

docker build \
  --build-arg MULTICA_VERSION="$MULTICA_VERSION" \
  --build-arg DSH_VERSION="$DSH_VERSION" \
  --build-arg DSH_MULTICA_RUNTIME_REPO="https://github.com/${DSH_MULTICA_RUNTIME_REPO}.git" \
  --build-arg DSH_MULTICA_RUNTIME_COMMIT="$DSH_MULTICA_RUNTIME_COMMIT" \
  -t dsh-with-multica:local \
  -f base/Dockerfile .
```

## Running locally

```bash
echo '{"server_url":"ws://localhost:8080/ws","workspace_id":"<your-workspace-id>","token":"<your-token>"}' > /tmp/multica-config.json

docker run --rm \
  -v /tmp/multica-config.json:/etc/multica/config.json:ro \
  -e OPENAI_BASE_URL=https://your-openai-compatible-endpoint/v1 \
  -e OPENAI_API_KEY=sk-... \
  -e OPENAI_MODEL=gpt-4o \
  dsh-with-multica:local
```

The container starts the multica daemon in the foreground. The daemon probes `dsh --profile multica --probe`, registers `dsh` as a runtime, and connects to the multica server. From the multica dashboard, you can then dispatch tasks to this runtime.

## Release flow

CI (`.github/workflows/build.yml`) does the following:

- **Push to `main`** (paths `base/**`, `versions.yaml`, or the workflow itself): builds `linux/amd64` and `linux/arm64` images, pushes them to GHCR as `latest-{arch}` and `{project.version}-{arch}`.
- **Push of a `v*` tag**: builds both arches again, pulls them back from GHCR, exports each as a `.tar.gz` via `docker save | gzip`, and attaches them to a GitHub Release.

To cut a release:

```bash
# 1. Bump versions.yaml's project.version (and any component versions as needed).
# 2. Commit and push to main — CI builds and pushes per-arch images to GHCR.
# 3. Tag and push:
git tag v0.1.0
git push origin v0.1.0
# 4. CI creates the GitHub Release with tar.gz assets.
```

## Bump checklist

When bumping any version in `versions.yaml`:

1. **`dsh.version`** — bump, then run a full image build (Task 5 in the implementation plan). If Stage 3 fails with an incompatible-plugin diagnostic from `dsh plugin`, the bridge bundle's `peerDependencies` no longer satisfy the new dsh's internal sub-packages. Prefer bumping `dsh_multica_runtime.commit` to a newer `main` HEAD with widened peer ranges; only fall back to `dsh plugin allow-version <pkg>@<version> --dsh-version <runtime-version> --accept-risk` invocations in Stage 3 after verifying the bridge's API surface hasn't broken. Re-verify the `cordis.patch.yml` overlay against the new dsh version's `llm-pi-ai/config.ts` schema (in `~/code/deepseek-harness` or the dsh npm package).
2. **`dsh_multica_runtime.commit`** — find a recent `main` HEAD (`gh api repos/multica-ai/dsh-multica-runtime/commits/main --jq .sha`), update the commit, run a full image build, verify the smoke tests pass.
3. **`multica.version`** — bump; the Stage 1 downloader URL changes, so a failed download fails the build loudly.
4. **`project.version`** — bump on every release; drives the GHCR image tag and the `v*` git tag.

## Notes

- `dsh` is at `0.1.7-rc.2` (developer preview). Breaking changes are possible on bump; the bump checklist above is the mitigation.
- The bridge bundle repo (`multica-ai/dsh-multica-runtime`) has no tags or releases — only a `main` branch. We pin a commit SHA, not a moving ref.
- No `sudo` is installed — there is no privileged background process (cc-proxy is gone). The entrypoint does its root-phase work and drops to the `agent` user before starting the multica daemon.
- The image is provider-agnostic: dsh calls whatever OpenAI-compatible endpoint the operator configures. DeepSeek's native API route is disabled in `base/cordis.patch.yml`.
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: add README with build/run/release instructions and bump checklist"
```

---

## Task 8: Final verification

**Files:**
- None (verification only)

A final end-to-end check that the local image builds, the entrypoint validation works, and the files committed match what's in the spec.

- [ ] **Step 1: Rebuild the image from a clean state**

Run:
```bash
eval "$(python3 -c "
import yaml
d = yaml.safe_load(open('versions.yaml'))
print(f'MULTICA_VERSION={d[\"multica\"][\"version\"]}')
print(f'DSH_VERSION={d[\"dsh\"][\"version\"]}')
print(f'DSH_MULTICA_RUNTIME_REPO={d[\"dsh_multica_runtime\"][\"repo\"]}')
print(f'DSH_MULTICA_RUNTIME_COMMIT={d[\"dsh_multica_runtime\"][\"commit\"]}')
")"
docker build \
  --no-cache \
  --build-arg MULTICA_VERSION="$MULTICA_VERSION" \
  --build-arg DSH_VERSION="$DSH_VERSION" \
  --build-arg DSH_MULTICA_RUNTIME_REPO="https://github.com/${DSH_MULTICA_RUNTIME_REPO}.git" \
  --build-arg DSH_MULTICA_RUNTIME_COMMIT="$DSH_MULTICA_RUNTIME_COMMIT" \
  -t dsh-with-multica:final \
  -f base/Dockerfile . 2>&1 | tail -10
```
Expected: build completes with `Successfully tagged dsh-with-multica:final`.

- [ ] **Step 2: Re-run the smoke checks from Task 5 against the final image**

Run:
```bash
docker run --rm dsh-with-multica:final sh -c 'command -v dsh && command -v multica && dsh --version && multica --version'
docker run --rm dsh-with-multica:final sh -c 'test -f /home/agent/.dsh/profiles/multica/package.json && echo profile-ok'
docker run --rm dsh-with-multica:final 2>&1 | head -3
```
Expected: both binaries on PATH, profile installed, entrypoint exits with the missing-config message.

- [ ] **Step 3: Verify the repo file tree matches the spec**

Run: `git ls-files`
Expected:
```
.github/workflows/build.yml
README.md
base/Dockerfile
base/cordis.patch.yml
base/entrypoint.sh
docs/superpowers/plans/2026-09-27-dsh-with-multica.md
docs/superpowers/specs/2026-09-27-dsh-with-multica-design.md
versions.yaml
```

- [ ] **Step 4: Verify all commits are in place**

Run: `git log --oneline`
Expected: commits for spec, plan, versions.yaml, cordis.patch.yml, entrypoint.sh, Dockerfile, build.yml, README, and any smoke-fix commits, in that order.

- [ ] **Step 5: Push the branch**

Run: `git push -u origin main`
Expected: the branch and all commits push to the remote. CI will trigger on the push.

---

## Self-review notes

This plan was reviewed against the spec at `docs/superpowers/specs/2026-09-27-dsh-with-multica-design.md`. Spec coverage:

- ✅ Repository layout (spec §"Repository layout") → Task 1 (versions.yaml), Task 4 (Dockerfile), Task 6 (build.yml)
- ✅ Dockerfile 4 stages (spec §"Dockerfile") → Task 4
- ✅ LLM configuration (spec §"LLM configuration") → Task 2 (cordis.patch.yml), baked into the image by Task 4's Stage 3
- ✅ Entrypoint (spec §"Entrypoint") → Task 3
- ✅ GitHub release flow (spec §"GitHub release flow") → Task 6
- ✅ Error handling (spec §"Error handling") → Task 3 (entrypoint validation), Task 4 (Stage 3 fails loudly on plugin/peerDep errors)
- ✅ Testing (spec §"Testing") → Tasks 5 and 8 (manual smoke build + verification; no automated tests, per spec)
- ✅ Risks (spec §"Risks and mitigations") → Task 7 README bump checklist documents the dsh peerDep risk and the bridge-bundle-commit pinning strategy

No placeholders. Type consistency checked: `MULTICA_AGENT_RUNTIME_NAME` / `MULTICA_DAEMON_DEVICE_NAME` / `OPENAI_BASE_URL` / `OPENAI_API_KEY` / `OPENAI_MODEL` / `GIT_TOKEN` / `GIT_USERNAME` / `GIT_HOST` are used identically in entrypoint, README, and the spec. Patch row id `llm-deepseek` (not `llm-deepseek-api-key`) is used consistently in Task 2's `cordis.patch.yml`.
