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

# Language toolchains stop here on purpose: Go, Rust, JDK and database clients
# are wanted by one project each and belong in config/packages.txt.
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        curl \
        file \
        git \
        gnupg \
        jq \
        less \
        openssh-client \
        patch \
        python3 \
        python3-pip \
        python3-venv \
        ripgrep \
        tmux \
        unzip \
        vim \
        wget \
        xz-utils \
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

# Docker engine, for repositories whose tests or dev loop are containers.
#
# sbx runs a real dockerd inside the sandbox, nested, but only starts it when
# the image asks for it with com.docker.sandboxes.start-docker (set at the
# bottom of this file) and only from binaries the image carries - which is why
# the daemon is installed here and not just the client. The daemon runs
# privileged while the agent keeps no capabilities of its own; it reaches the
# engine through the socket, which dockerd creates as root:docker, so the agent
# is added to that group where it is created below.
RUN curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        -o /usr/share/keyrings/docker.asc \
    && chmod go+r /usr/share/keyrings/docker.asc \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
        > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        containerd.io \
        docker-ce \
        docker-ce-cli \
        docker-buildx-plugin \
        docker-compose-plugin \
    && rm -rf /var/lib/apt/lists/*

# Interactive agent CLIs
RUN npm install -g \
        @anthropic-ai/claude-code \
        @google/gemini-cli \
        @openai/codex

# Antigravity CLI (agy), which ships no image of its own.
#
# The installer drops the binary in $HOME/.local/bin, and HOME is the project
# volume root at runtime - a different directory per project, and not one that
# exists at build time. Installing under /opt and linking into /usr/local/bin
# puts it on PATH for every project, the same treatment kimi-code needs.
#
# agy stores its state under ~/.gemini/antigravity-cli, which lands in the
# volume root and therefore survives restarts: log in once per project.
RUN set -eux; \
    export HOME=/opt/agy; \
    mkdir -p "$HOME"; \
    curl -fsSL https://antigravity.google/cli/install.sh | bash; \
    ln -sf "$HOME/.local/bin/agy" /usr/local/bin/agy; \
    chmod -R a+rX /opt/agy; \
    /usr/local/bin/agy --version

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

# Shared session-ledger helpers, sourced by the agent start scripts and watcher
# adapters. The golden image used to install these; the image carries them now.
COPY templates/agent-session.sh /opt/foundry/agent-session.sh
RUN chmod 0755 /opt/foundry/agent-session.sh

# Shared prompt builder, sourced by every watcher adapter. Single source of
# truth for the execution contract, task modes, and the agent identity string
# (see docs/PROMPT-ARCHITECTURE.md). Baked into the image for the same reason
# as agent-session.sh: the VM backend copied it in per-VM, the sandbox carries
# it instead.
COPY templates/prompt-lib.sh /opt/foundry/prompt-lib.sh
RUN chmod 0755 /opt/foundry/prompt-lib.sh

# The goal-mode adapter and the launcher it runs, shared by claude-goal,
# codex-goal and agy-goal. The launcher is the single copy of each CLI's
# invocation: the adapter execs it rather than restating the command lines.
COPY templates/goal/watcher_agent_goal.sh /opt/foundry/watcher_agent_goal.sh
COPY templates/goal/start-goal.sh.template /opt/foundry/start-goal.sh
RUN chmod 0755 /opt/foundry/watcher_agent_goal.sh /opt/foundry/start-goal.sh

# The Forgejo watcher: receiver, main loop, shared helpers and hook manager.
# It reads its configuration from the agent's home, which is the project's
# volume root, so one image serves every project.
COPY templates/forgejo/ /opt/foundry/forgejo/
RUN chmod 0755 /opt/foundry/forgejo/*.sh

# forgejo-cli, used by the Forgejo watcher adapters.
COPY binaries/fj/ /tmp/fj/
RUN set -eux; \
    binary="$(find /tmp/fj -maxdepth 1 -type f | sort | tail -n 1)"; \
    if [ -n "$binary" ]; then install -m 0755 "$binary" /usr/local/bin/fj; fi; \
    rm -rf /tmp/fj

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
    # No -m: the home is created at runtime as a symlink to the project's
    # volume root, so the agent lives in a normal /home/agent while its files
    # are the ones on the host. A real directory here would be in the way, and
    # ssh - which resolves ~ from the passwd entry, not $HOME - would read it
    # instead of the project's .ssh.
    # The docker package creates this group, but not on a rebuild that skips
    # that layer; either way the agent must be in it to reach the socket.
    getent group docker >/dev/null || groupadd docker; \
    useradd -M -d "/home/${AGENT_USER}" -u "${AGENT_UID}" -g "${AGENT_GID}" -G docker -s /bin/bash "${AGENT_USER}"; \
    apt-get update && apt-get install -y --no-install-recommends sudo; \
    rm -rf /var/lib/apt/lists/*; \
    echo "${AGENT_USER} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/${AGENT_USER}"; \
    chmod 0440 "/etc/sudoers.d/${AGENT_USER}"

USER ${AGENT_USER}

# HOME is set per-exec by Foundry to the mounted volume root; this is only the
# fallback for a bare shell.
# The real working directory is the volume root, mounted at runtime and linked
# from /home/${AGENT_USER}; this is only the fallback for a bare shell.
WORKDIR /

# start-docker is what makes sbx launch the nested daemon: without this label
# the engine installed above is inert and /var/run/docker.sock never appears.
LABEL org.opencontainers.image.title="Agent Foundry sandbox" \
      org.opencontainers.image.description="Sandbox image for Agent Foundry projects" \
      io.foundry.ralph-variant="${RALPH_VARIANT}" \
      com.docker.sandboxes.start-docker="true"
