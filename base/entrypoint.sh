#!/usr/bin/env bash
set -euo pipefail

# Root phase: create directories, write git credentials, fix ownership, then
# re-exec as the unprivileged agent user.
if [ "$(id -u)" = "0" ]; then
  mkdir -p /etc/multica /home/agent/.multica /home/agent/.dsh /home/agent/.dsh/skills /home/agent/wiki

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
