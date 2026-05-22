ARG VERSION=dev-1
FROM docker:cli AS docker-cli

FROM debian:sid-slim

COPY --from=docker-cli /usr/local/bin/docker /usr/local/bin/docker

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    ca-certificates \
    curl \
    fd-find \
    ffmpeg \
    ffprobe \
    file \
    git \
    htop \
    jq \
    less \
    make \
    nodejs \
    npm \
    python3 \
    python3-pip \
    ripgrep \
    sudo \
    tree \
    vim \
    wget \
  && rm -r /var/lib/apt/lists/*

SHELL ["/usr/bin/env", "bash", "-c"]

RUN if (( BASH_VERSINFO[0] < 5 )); then \
      printf 'bash >= 5 required, got %s\n' "$BASH_VERSION" >&2; \
      exit 1; \
    fi

RUN printf '%s\n' '#!/usr/bin/env bash' 'exec bash "$@"' > /usr/local/bin/env-bash \
  && chmod +x /usr/local/bin/env-bash

# fd-find installs as 'fdfind'; symlink to 'fd' for ergonomics
RUN ln -s /usr/bin/fdfind /usr/local/bin/fd

RUN npm install -g @earendil-works/pi-coding-agent

RUN groupadd --system docker \
  && useradd --create-home --uid 1000 --shell /usr/local/bin/env-bash agent \
  && usermod -aG docker,sudo agent \
  && printf 'agent ALL=(ALL) NOPASSWD: ALL\n' > /etc/sudoers.d/agent \
  && chmod 0440 /etc/sudoers.d/agent

RUN mkdir -p /home/agent/.claude && chown agent:agent /home/agent/.claude
COPY --chown=agent:agent src/claude-settings.json /home/agent/.claude/settings.json

ARG VERSION
LABEL org.opencontainers.image.version="$VERSION"

WORKDIR /workspace

USER agent
