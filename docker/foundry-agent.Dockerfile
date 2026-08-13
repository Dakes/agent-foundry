# Agent Foundry - sandbox image
#
# Replaces the golden-image pipeline (build-ubuntu-base.sh, prepare-kernel.sh,
# build-golden.sh). The image carries binaries only: all per-project state -
# auth, agent memory, prompts, repos - lives in the mounted volume root, so
# nothing here needs to be baked per project.
#
# The interactive CLIs (claude, gemini, codex) are the primary target and are
# always present. The autonomous Ralph variants are optional extras: one per
# image, matching the pre-migration rule that a VM hosts a single variant.
#
# Build:
#   foundry image build                    -> foundry-agent:base (claude/gemini/codex)
#   foundry image build ralph              -> + frankbria/ralph-claude-code
#   foundry image build ralph-orchestrator -> + @ralph-orchestrator/ralph-cli
#   foundry image build kimi-ralph         -> + kimi-code
#
# Use:
#   set .image in a project's foundry.json, or FOUNDRY_IMAGE_REPO globally.

ARG BASE_IMAGE=ubuntu:24.04
FROM ${BASE_IMAGE}

# "none" builds the base image: the interactive CLIs only.
ARG RALPH_VARIANT=none

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        gnupg \
        jq \
        openssh-client \
        python3 \
        python3-pip \
        python3-venv \
        ripgrep \
        tmux \
        unzip \
        vim \
    && rm -rf /var/lib/apt/lists/*

# Node.js (agent CLIs are npm-distributed)
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# GitHub CLI
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# Interactive agent CLIs
RUN npm install -g \
        @anthropic-ai/claude-code \
        @google/gemini-cli \
        @openai/codex

# Optional autonomous agent variant.
#
# These recipes are the ones lib/workspace.sh used to run per-VM, not npm
# guesses: "ralph" is a git checkout with its own installer (there is no
# ralph-claude-code package on npm), ralph-orchestrator is a scoped npm
# package, and kimi-code ships its own install script. Each ends with
# /usr/local/bin/<binary> so agent_binary() from the registry resolves.
# HOME is redirected to /opt/agent-tools for the installers that drop files
# into the home directory: as root that would be /root, which is mode 700 and
# therefore unreadable by the unprivileged agent user this image runs as.
RUN set -eux; \
    export HOME=/opt/agent-tools; \
    mkdir -p "$HOME"; \
    case "${RALPH_VARIANT}" in \
        none) \
            echo "No autonomous variant requested; interactive CLIs only" ;; \
        ralph) \
            git clone --depth 1 https://github.com/frankbria/ralph-claude-code.git /opt/ralph; \
            cd /opt/ralph; \
            ./install.sh; \
            ln -sf "$(command -v ralph)" /usr/local/bin/ralph ;; \
        ralph-orchestrator) \
            npm install -g @ralph-orchestrator/ralph-cli; \
            ln -sf "$(command -v ralph)" /usr/local/bin/ralph ;; \
        kimi-ralph) \
            curl -fsSL https://code.kimi.com/kimi-code/install.sh | bash; \
            ln -sf "${HOME}/.kimi-code/bin/kimi" /usr/local/bin/kimi ;; \
        *) \
            echo "Unknown RALPH_VARIANT: ${RALPH_VARIANT}" >&2; exit 1 ;; \
    esac; \
    chmod -R a+rX /opt; \
    printf '%s\n' "${RALPH_VARIANT}" > /etc/foundry-ralph-variant

# Extra packages, if the operator maintains a list. The apt lists were removed
# by the layers above, so this needs its own update before it can install.
COPY config/packages.txt /tmp/packages.txt
RUN if [ -s /tmp/packages.txt ] && grep -qvE '^\s*(#|$)' /tmp/packages.txt; then \
        apt-get update && \
        grep -vE '^\s*(#|$)' /tmp/packages.txt \
            | xargs -r apt-get install -y --no-install-recommends; \
    fi; \
    rm -f /tmp/packages.txt; \
    rm -rf /var/lib/apt/lists/*

# The agent user, matching the host user's UID/GID.
#
# Everything the agent writes goes into the mounted volume root, which is a
# host directory: running as root would leave root-owned files the user cannot
# edit. Foundry passes the invoking user's real UID/GID at build time
# (see cmd_image), so ownership is identical on both sides of the mount.
ARG AGENT_UID=1000
ARG AGENT_GID=1000
ARG AGENT_USER=agent

RUN set -eux; \
    # ubuntu:24.04 ships an "ubuntu" user on 1000; free the ID if it collides.
    if existing="$(getent passwd "${AGENT_UID}" | cut -d: -f1)" && [ -n "$existing" ]; then \
        userdel -r "$existing" 2>/dev/null || userdel "$existing"; \
    fi; \
    if ! getent group "${AGENT_GID}" >/dev/null; then \
        groupadd -g "${AGENT_GID}" "${AGENT_USER}"; \
    fi; \
    useradd -m -u "${AGENT_UID}" -g "${AGENT_GID}" -s /bin/bash "${AGENT_USER}"; \
    apt-get update && apt-get install -y --no-install-recommends sudo; \
    rm -rf /var/lib/apt/lists/*; \
    echo "${AGENT_USER} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/${AGENT_USER}"; \
    chmod 0440 "/etc/sudoers.d/${AGENT_USER}"

USER ${AGENT_USER}

# HOME is set per-exec by Foundry to the mounted volume root; this is only the
# fallback for a bare shell.
WORKDIR /home/${AGENT_USER}

LABEL org.opencontainers.image.title="Agent Foundry sandbox" \
      org.opencontainers.image.description="Sandbox image for Agent Foundry projects" \
      io.foundry.ralph-variant="${RALPH_VARIANT}"
