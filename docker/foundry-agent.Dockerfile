# Agent Foundry - sandbox image
#
# Replaces the golden-image pipeline (build-ubuntu-base.sh, prepare-kernel.sh,
# build-golden.sh). The image carries binaries only: all per-project state -
# auth, agent memory, prompts, repos - lives in the mounted volume root, so
# nothing here needs to be baked per project.
#
# Build:
#   foundry image build ralph
#   foundry image build ralph-orchestrator
#   foundry image build kimi-ralph
#
# Use:
#   set .image in a project's foundry.json, or FOUNDRY_IMAGE_REPO globally.

ARG BASE_IMAGE=ubuntu:24.04
FROM ${BASE_IMAGE}

# Exactly one autonomous agent variant per image, matching the pre-migration
# rule that a VM hosts a single Ralph variant.
ARG RALPH_VARIANT=ralph

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

# Autonomous agent variant
RUN set -eux; \
    case "${RALPH_VARIANT}" in \
        ralph) \
            npm install -g ralph-claude-code ;; \
        ralph-orchestrator) \
            pip3 install --break-system-packages ralph-orchestrator ;; \
        kimi-ralph) \
            npm install -g kimi-cli ;; \
        *) \
            echo "Unknown RALPH_VARIANT: ${RALPH_VARIANT}" >&2; exit 1 ;; \
    esac

# Extra packages, if the operator maintains a list.
COPY config/packages.txt /tmp/packages.txt
RUN if [ -s /tmp/packages.txt ]; then \
        grep -vE '^\s*(#|$)' /tmp/packages.txt | xargs -r apt-get install -y --no-install-recommends || true; \
    fi; \
    rm -f /tmp/packages.txt; \
    rm -rf /var/lib/apt/lists/*

# HOME is set per-exec by Foundry to the mounted volume root; this is only the
# fallback for a bare shell.
WORKDIR /root

LABEL org.opencontainers.image.title="Agent Foundry sandbox" \
      org.opencontainers.image.description="Sandbox image for Agent Foundry projects" \
      io.foundry.ralph-variant="${RALPH_VARIANT}"
