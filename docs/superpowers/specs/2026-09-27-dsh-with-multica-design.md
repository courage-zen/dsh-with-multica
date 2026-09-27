# dsh-with-multica — runtime image design

**Date:** 2026-09-27
**Status:** Draft (pending user approval)
**Scope:** Base image only. No derived variants.

## Purpose

A Docker runtime image that registers DeepSeek Harness (`dsh`) as a coding-agent
runtime under a Multica daemon. The image is built once, published to GHCR on
every `main` push, and released as per-arch `docker save` tarballs attached to
GitHub Releases on `v*` tags. It mirrors the structure of the sibling project
`agents-with-multica/base/`, substituting dsh for claude+opencode and dropping
the cc-proxy LLM relay.

The image is **provider-agnostic**: dsh calls a third-party OpenAI-compatible
endpoint supplied by the operator at runtime via env vars. It does not use
DeepSeek's native API.

## Repository layout

```
dsh-with-multica/
├── versions.yaml                          # single source of truth for pinned versions
├── base/
│   ├── Dockerfile                          # 4-stage build
│   └── entrypoint.sh                       # root→agent drop, multica daemon start
└── .github/
    └── workflows/
        └── build.yml                       # GHCR push + GitHub release with tarballs
```

`versions.yaml` schema:

```yaml
project:
  version: "0.1.0"           # this project's release version (drives v* tags)
dsh:
  version: "0.1.7-rc.2"      # @deepseek-ai/dsh npm version
multica:
  version: "0.5.3"           # multica-ai/multica GitHub release tag
  repo: "multica-ai/multica"
dsh_multica_runtime:
  repo: "multica-ai/dsh-multica-runtime"
  commit: "e29aae228449dfe50e88af60ef4281e38ca44e2a"  # main as of 2026-09-27; no tags exist yet
```

Every version is a build ARG with **no default** in the Dockerfile. Bumping any
component is a single-file edit to `versions.yaml`. Both `build.yml` and the
Dockerfile read from it; CI extracts values with inline Python `yaml.safe_load`,
the same pattern as the reference project.

## Dockerfile (4 stages)

### Stage 1 — `multica-downloader` (Alpine 3.20)

- **Args:** `MULTICA_VERSION`, `TARGETARCH`
- Downloads `https://github.com/multica-ai/multica/releases/download/v${MULTICA_VERSION}/multica-cli-${MULTICA_VERSION}-linux-${ARCH}.tar.gz`
  (where `ARCH` is `x86_64` when `TARGETARCH=amd64`, `aarch64` when `arm64` — same mapping as the reference)
- Extracts and outputs `/out/multica`

### Stage 2 — `bundle-source` (Alpine 3.20 + git)

- **Args:** `DSH_MULTICA_RUNTIME_REPO`, `DSH_MULTICA_RUNTIME_COMMIT`
- `git clone --filter=blob:none ${DSH_MULTICA_RUNTIME_REPO} /out/dsh-multica-runtime`
- `git -C /out/dsh-multica-runtime checkout ${DSH_MULTICA_RUNTIME_COMMIT}`
- Outputs `/out/dsh-multica-runtime`

### Stage 3 — `dsh-profile-install` (`node:22-bookworm-slim`)

- **Args:** `DSH_VERSION`
- `npm install -g @deepseek-ai/dsh@${DSH_VERSION} pnpm`
- `COPY --from=bundle-source /out/dsh-multica-runtime /dsh-multica-runtime`
- Creates the `agent` user with **UID 1000**, home `/home/agent`, shell `/bin/bash`
- `ENV HOME=/home/agent DSH_HOME=/home/agent/.dsh`
- Runs `dsh plugin --profile multica add /dsh-multica-runtime` — this:
  - Creates `/home/agent/.dsh/profiles/multica/`
  - Installs the `@multica-ai/dsh-runtime` bridge bundle (which provides the
    Multica stdio protocol surface: system-prompt persona, session-persistence,
    headless-runner, telemetry disable, HMR disable)
- Writes `/home/agent/.dsh/profiles/multica/cordis.patch.yml` (overwriting
  the empty `[]` template the profile init step created) with the
  env-driven LLM provider overlay (see "LLM configuration" below)
- Outputs: `/home/agent/.dsh/` (profile + the global node_modules that contain
  dsh and its bundled plugins)

### Stage 4 — final (`node:22-bookworm-slim`)

- Installs runtime OS packages: `git`, `ca-certificates`, `curl`, `openssh-client`
  - **No `sudo`**, no sudoers rule — there is no privileged background process
    to start (cc-proxy is gone)
- Creates the `agent` user with the **same UID 1000** (so ownership copied from
  stage 3 is consistent)
- Copies from stage 1: `multica` binary → `/usr/local/bin/multica`
- Copies from stage 3:
  - dsh CLI + global node_modules → `/usr/local/bin/dsh` symlink +
    `/usr/local/lib/node_modules`
  - `/home/agent/.dsh/` (the pre-built multica profile) → `/home/agent/.dsh/`
- Copies `base/entrypoint.sh` → `/entrypoint.sh`, `chmod +x`
- Creates runtime directories: `/home/agent/wiki`
- Sets system-level git config: `credential.helper store`,
  `user.name agent`, `user.email agent@container`
- `WORKDIR /home/agent`
- `ENTRYPOINT ["/entrypoint.sh"]`

**Differences from the reference (`agents-with-multica/base/Dockerfile`):**
- Removed: `cc-proxy-downloader` stage, `claude-install` stage, `sudo` package,
  the sudoers rule for `cc-proxy start`, opencode install + symlinks,
  `~/.claude/skills`, `~/.opencode`, `/etc/opencode`
- Added: `bundle-source` stage (git clone), `dsh-profile-install` stage
  (npm install dsh + `dsh plugin --profile multica add`), env-driven
  `cordis.patch.yml` written into the profile directory

## LLM configuration

The bridge bundle wires Multica protocol surface only — it does **not** declare
any LLM provider. The image bakes an env-driven provider route into the
profile's `cordis.patch.yml` so a single image serves any OpenAI-compatible
endpoint.

File written at build time to `/home/agent/.dsh/profiles/multica/cordis.patch.yml`:

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

**Operator-supplied env vars at runtime** (via multica dashboard `custom_env`
or `docker run -e`):

| Var | Required | Purpose |
|---|---|---|
| `OPENAI_BASE_URL` | yes | Third-party OpenAI-compatible endpoint URL |
| `OPENAI_API_KEY` | yes | The literal env-var name `OPENAI_API_KEY`; dsh resolves the actual secret value per request through its credential-ref system |
| `OPENAI_MODEL` | yes | Model ID to dispatch (multica sends `Model: {Provider: "openai", ID: <OPENAI_MODEL>}` on each execute) |
| `OPENAI_PROVIDER_NAME` | no | Display name in dsh model picker (default `OpenAI`) |
| `OPENAI_MODEL_NAME` | no | Display name for the model (default falls back to `OPENAI_MODEL`) |
| `OPENAI_CONTEXT_WINDOW` | no | Context window in tokens (default `128000`) |
| `OPENAI_MAX_TOKENS` | no | Max output tokens (default `16384`) |

**Why `apiKeyEnv: OPENAI_API_KEY` is a literal string, not a secret:** dsh's
`llm-pi-ai` plugin reads `apiKeyEnv` as the *name* of an env var to resolve per
request. The secret value is whatever `OPENAI_API_KEY` is set to in the
container's environment. The patch YAML never contains the secret itself.

**Why disable `llm-deepseek`:** The dsh-base bundle ships a route (`id: llm-deepseek`, package `@deepseek-ai/dsh-llm-deepseek-api-key`) that expects `DEEPSEEK_API_KEY`. Since this image explicitly does not use DeepSeek's native API, an unset `DEEPSEEK_API_KEY` would cause `dsh --profile multica --probe` to surface a `MISSING_CREDENTIAL` error unrelated to the actual OpenAI-compatible endpoint, making the daemon report a misleading "runtime missing" status.

## Plugin composition and version management

### What the multica profile actually contains

`dsh plugin --profile multica add @multica-ai/dsh-runtime` produces a profile with exactly two bundles:

1. **`@deepseek-ai/dsh-base`** — auto-added by `dsh plugin add` (it's `DEFAULT_PROFILE_BUNDLES` in dsh-app-boot). This single bundle's `cordis.patch.yml` mounts ~40 core plugins, including:
   - Core agent loop: `agent` (`@deepseek-ai/dsh-agent`), `llm`, `session`, `mcp-client`, `subprocess`, `user-approval`, `cmdline`
   - LLM providers: `llm-pi-ai` (`@deepseek-ai/dsh-llm-pi-ai`, mounted dormant until a settings/patch section supplies provider profiles — exactly what our `cordis.patch.yml` overlay does), `llm-deepseek` (`@deepseek-ai/dsh-llm-deepseek-api-key`, the DeepSeek-native route we disable)
   - Session persistence: `session-persistence-jsonl`, `session-projection`, `session-query-sqlite`, `attachment-local`
   - Storage/credentials: `storage`, `storage-json`, `credentials`, `authorization`
   - Misc: `timer`, `hmr`, `session-telemetry-otel`, `plugin-manager`, `config-editor`, `settings`
2. **`@multica-ai/dsh-runtime`** (the bridge bundle) — adds `headless-runner` (the stdio protocol surface multica's daemon talks to), disables `hmr` and `telemetry-otel`, configures `session-persistence-jsonl` root via `MULTICA_DSH_SESSION_ROOT`, sets the `system-prompt` persona.

**No additional plugins need to be installed.** Both LLM provider routes we touch (`llm-pi-ai` activate, `llm-deepseek` disable) ship with `dsh-base`.

### Version pinning strategy

| Component | Pinned separately? | Reason |
|---|---|---|
| `@deepseek-ai/dsh` (the CLI) | Yes — `versions.yaml: dsh.version` | Top-level package |
| `@deepseek-ai/dsh-base` and all `@deepseek-ai/dsh-*` sub-packages | **No** — they follow dsh automatically | Transitive dependencies of the dsh CLI, locked by dsh's own `pnpm-lock.yaml`. Pinning them separately would either be redundant (matching dsh's lockfile) or dangerous (diverging from it breaks the runtime). Bumping `dsh.version` bumps them all in lockstep. |
| `@multica-ai/dsh-runtime` (bridge bundle) | Yes — `versions.yaml: dsh_multica_runtime.commit` | The only external dependency not on the public npm registry. Built from source at the pinned commit. |
| `multica` CLI | Yes — `versions.yaml: multica.version` | Downloaded from GitHub releases. |

### peerDependency compatibility — the real bump risk

The bridge bundle's `package.json` declares `peerDependencies` on a subset of `@deepseek-ai/dsh-*` packages (e.g. `@deepseek-ai/dsh-agent: ^0.1.0-rc.6`, `@deepseek-ai/dsh-llm: ^0.1.0-rc.6`, plus `@deepseek-ai/cordis: ^4.0.1`). When dsh is bumped to a version whose internal sub-packages no longer satisfy these peer ranges, `dsh plugin --profile multica add` reports the package as **incompatible** and refuses to install it. The operator must then run `dsh plugin --profile multica allow-version <pkg>@<version> --dsh-version <runtime-version> --accept-risk` for each flagged package to record an exemption in the profile's compatibility store.

This is the single most likely failure mode when bumping `dsh.version`. The bump checklist must include: after changing `dsh.version`, run a full image build; if Stage 3 fails with an incompatible-plugin diagnostic, either (a) bump `dsh_multica_runtime.commit` to a newer main HEAD that widens its peer ranges, or (b) add `dsh plugin allow-version` invocations to Stage 3 for the flagged packages after explicit verification that the API surface the bridge uses hasn't broken. Option (a) is preferred when available.


## Entrypoint (`base/entrypoint.sh`)

Two-phase, root → agent drop, mirroring the reference's pattern.

### Root phase (`id -u == 0`)

1. Create directories: `/etc/multica`, `/home/agent/.multica`, `/home/agent/.dsh`,
   `/home/agent/wiki`
2. If `GIT_TOKEN` is set, write `~/.git-credentials` with
   `https://<GIT_USERNAME>:<GIT_TOKEN>@<GIT_HOST>` (GIT_USERNAME defaults to
   `oauth2`, GIT_HOST is required when GIT_TOKEN is set)
3. `chown -R agent:agent /home/agent` to fix ownership of all the dirs from
   stage 3's copies
4. Re-exec itself as `agent`: `su -p -s /bin/bash agent -c "HOME=/home/agent exec $0"`
   (`-p` preserves the environment, including the multica and OpenAI env vars)

### Agent phase (running as `agent`)

1. Validate `/etc/multica/config.json` exists — fatal exit with a clear message
   if missing (operator forgot the read-only mount)
2. Copy `/etc/multica/config.json` → `~/.multica/config.json`
3. Validate LLM env vars: if any of `OPENAI_BASE_URL`, `OPENAI_API_KEY`,
   `OPENAI_MODEL` is unset, exit with a clear message naming the missing var.
   This prevents the daemon from starting a runtime whose probe will fail with
   a misleading error
4. Exec `multica daemon start --runtime-name "${MULTICA_AGENT_RUNTIME_NAME:-Docker}" --device-name "${MULTICA_DAEMON_DEVICE_NAME:-Docker}"`

### Environment variables consumed

| Var | Default | Purpose |
|---|---|---|
| `MULTICA_AGENT_RUNTIME_NAME` | `Docker` | Display name in multica dashboard |
| `MULTICA_DAEMON_DEVICE_NAME` | `Docker` | Device identifier in multica |
| `GIT_TOKEN` | (none) | Git push credential |
| `GIT_USERNAME` | `oauth2` | Git credential username |
| `GIT_HOST` | (none, required if `GIT_TOKEN` set) | Git credential host |
| `OPENAI_BASE_URL` | (required) | OpenAI-compatible endpoint |
| `OPENAI_API_KEY` | (required) | Env-var name dsh resolves per request |
| `OPENAI_MODEL` | (required) | Model ID for dispatch |

### Volume mounts (operator supplies at runtime, read-only)

| Mount | Purpose |
|---|---|
| `/etc/multica/config.json` (ro) | multica daemon config: server URL, workspace ID, token |
| `/home/agent/wiki` (ro) | Reference docs the agent can read |

## GitHub release flow

Mirrors `agents-with-multica/.github/workflows/build.yml` exactly, minus the
derived-image jobs.

### Triggers

- Push to `main` when paths `base/**`, `versions.yaml`, or the workflow itself
  change
- Push of tags matching `v*`
- Pull requests on the same paths

### Job `build` (runs on push or PR)

1. Checkout, QEMU setup, Buildx setup, GHCR login
2. Extract versions from `versions.yaml` via inline Python (`yaml.safe_load`)
3. Build and push `dsh-with-multica` for **amd64** (two tags: `latest-amd64`
   and `{project.version}-amd64`)
4. Build and push `dsh-with-multica` for **arm64** (two tags: `latest-arm64`
   and `{project.version}-arm64`)
5. Push only on push events, not PRs (PRs build for validation only)

### Job `release` (depends on `build`, only on `v*` tags)

1. Extract the tag version from `$GITHUB_REF`
2. Login to GHCR
3. Pull both per-arch images from GHCR
4. `docker save dsh-with-multica:{version}-amd64 | gzip > dsh-with-multica-{version}-amd64.tar.gz`
5. Same for arm64
6. Create a GitHub Release via `softprops/action-gh-release@v2` with both
   tar.gz files as assets

### Release flow summary

```
Bump versions.yaml -> commit -> push to main
  -> CI builds + pushes per-arch images to GHCR

git tag v0.1.0 && git push origin v0.1.0
  -> CI builds images again
  -> pulls them back from GHCR
  -> exports as tar.gz
  -> creates GitHub Release with tar.gz assets
```

**Differences from the reference workflow:**
- No `build-code-writer-ts` / `build-code-writer-py` jobs (no derived images)
- Single image name `dsh-with-multica` (vs `agents-with-multica-npm` plus
  derived variants)
- Two release assets (amd64, arm64) instead of six
- No multi-arch manifest (matches reference — per-arch tags only)

## Error handling

**Build-time:**
- Every version ARG has no default; CI fails loudly if `versions.yaml` is
  missing a field
- Bundle-clone stage fails if the pinned commit SHA is unavailable —
  intentional, surfaces a disappeared upstream immediately
- `dsh plugin --profile multica add` failure (network, pnpm, bundle build)
  fails the stage loudly

**Runtime entrypoint:**
- Fatal exit with clear message for: missing `/etc/multica/config.json`; missing
  `OPENAI_BASE_URL` / `OPENAI_API_KEY` / `OPENAI_MODEL`
- Env-var validation runs *before* `multica daemon start`, so the daemon never
  starts a runtime whose probe will fail with a misleading error

**Runtime daemon:**
- dsh profile-load failures surface through multica's `/health` as
  `dshProbeMissingProfile` or probe failure — same diagnostic path multica
  already documents

## Testing

- **No automated tests in this repo.** The image is a thin packaging layer over
  existing, already-tested components (dsh, multica CLI, bridge bundle). Adding
  test infrastructure would be disproportionate to the deliverable.
- **Manual smoke test** (documented in README): build locally, run with env
  vars and a mounted `/etc/multica/config.json`, verify `multica daemon start`
  registers dsh as a runtime in the dashboard, dispatch a trivial task, confirm
  the agent runs to completion.
- **CI smoke check (optional, deferred):** on PR builds, run
  `docker run --rm dsh-with-multica:{version}-amd64 dsh --version` and
  `docker run --rm dsh-with-multica:{version}-amd64 multica --version` to catch
  binary-copy regressions. Not blocking for v0.1.0; add later if regressions
  appear.

## Risks and mitigations

| Risk | Mitigation |
|---|---|
| dsh is `0.1.7-rc.2` (developer preview, breaking changes possible) | Pin exact version in `versions.yaml`; bump deliberately. Document the preview status in README. |
| Bridge bundle repo has no releases/tags — only `main` branch commits | Pin a specific commit SHA, not `main`. Document how to bump (find a recent SHA, run a build, merge if green). |
| `dsh plugin --profile multica add` needs network + pnpm registry access at build time | Stage 3 installs pnpm globally first; build runs in CI with network. If registry is flaky, build fails loudly (acceptable). |
| **Bridge bundle's `peerDependencies` may break when dsh is bumped** (e.g. dsh 0.2.0 ships `@deepseek-ai/dsh-agent@0.2.0` which no longer satisfies `^0.1.0-rc.6`) | Stage 3 surfaces the failure loudly via `dsh plugin`'s incompatible-plugin report. Bump checklist: prefer bumping `dsh_multica_runtime.commit` to a newer main HEAD with widened peer ranges; only fall back to `dsh plugin allow-version` after verifying the bridge's API surface hasn't broken. See "peerDependency compatibility" above. |
| `llm-pi-ai` provider route syntax is internal dsh config — could break on dsh upgrade | Pin dsh version; when bumping dsh, re-verify the patch YAML against the new version's `llm-pi-ai/config.ts` schema. Document this in the bump checklist. |
| UID 1000 collision on host bind-mounts | Document that `agent` is UID 1000; operator is responsible for volume ownership. Same posture as reference project. |
| Bridge bundle's own `cordis.patch.yml` may evolve and conflict with our overlay | Our overlay is applied by dsh's patch composition (loader applies bundle's patch first, then profile's patch). Pin both the bundle commit and dsh version together; re-verify on bump. |

## Out of scope (YAGNI)

- Derived images (code-writer/ts, code-writer/py) — base image only
- Multi-arch manifest — reference doesn't use one, keeping parity
- Automated integration tests — disproportionate to deliverable
- cc-proxy or any LLM relay — dsh calls the OpenAI endpoint directly
- DeepSeek-native API support — explicitly disabled, operator only configures
  OpenAI-format endpoint
- `MULTICA_DSH_PROFILE_BUNDLE` runtime auto-install path — we bake the profile
  at build time, so this daemon feature is never exercised
