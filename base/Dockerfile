# syntax=docker/dockerfile:1.7

# ---------- Stage 1: multica CLI downloader ----------
FROM alpine:3.20 AS multica-downloader
ARG MULTICA_VERSION
ARG TARGETARCH
RUN apk add --no-cache wget && \
    wget -q -O /tmp/multica.tar.gz \
      "https://github.com/multica-ai/multica/releases/download/v${MULTICA_VERSION}/multica-cli-${MULTICA_VERSION}-linux-${TARGETARCH}.tar.gz" && \
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
# Create the agent user with a fixed UID. --non-unique is needed because the
# node base image already has a `node` user at UID 1000.
RUN useradd --uid 1000 --non-unique --create-home --shell /bin/bash agent
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
RUN useradd --uid 1000 --non-unique --create-home --shell /bin/bash agent
# multica CLI from stage 1.
COPY --from=multica-downloader /out/multica /usr/local/bin/multica
# dsh's global node_modules from stage 3. The npm global layout puts packages
# at /usr/local/lib/node_modules; the dsh binary is a symlink into this tree.
# We copy node_modules and recreate the symlink in the final stage rather than
# copying the symlink directly (COPY follows symlinks, which would break ESM
# module resolution).
COPY --from=dsh-profile-install /usr/local/lib/node_modules /usr/local/lib/node_modules
RUN ln -sf ../lib/node_modules/@deepseek-ai/dsh/lib/bin.js /usr/local/bin/dsh
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
# No USER agent directive: the entrypoint starts as root (to create dirs,
# write git credentials, fix ownership) and then drops to the agent user via
# `su -p -s /bin/bash agent`.
WORKDIR /home/agent
ENTRYPOINT ["/entrypoint.sh"]
