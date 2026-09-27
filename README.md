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
