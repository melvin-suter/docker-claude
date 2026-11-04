FROM ubuntu:24.04

# Prevent interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Developer tooling
RUN apt-get update && apt-get install -y \
      build-essential \
      git curl wget ca-certificates \
      openssh-client \
      bash zsh \
      ripgrep jq fzf tree htop less \
      procps sudo \
      unzip xz-utils \
      python3 python3-pip python3-venv \
    && rm -rf /var/lib/apt/lists/*

# Install Node.js 22 via NodeSource
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - && \
    apt-get install -y nodejs && \
    rm -rf /var/lib/apt/lists/*

# Create non-root developer user
RUN useradd -m -s /bin/bash -G sudo developer && \
    echo "developer ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/developer && \
    chmod 0440 /etc/sudoers.d/developer

# Everything baked into the image lives OUTSIDE /home/developer, because the home
# directory is typically replaced by a persistent volume at runtime. Per-user state
# (~/.ssh, ~/.claude, ~/.claude.json, ...) is created by the entrypoint instead.

# SSH: auto-accept host keys of any (not yet known) host, system-wide
RUN printf '%s\n' \
      'Host *' \
      '    StrictHostKeyChecking accept-new' \
      > /etc/ssh/ssh_config.d/10-accept-new-hostkeys.conf

# Install Claude Code CLI using the official installer, then move the binary
# out of the home directory so it survives a volume mounted over /home/developer.
# The ARG is declared here (not at the top) so a new version only rebuilds from this layer.
ARG CLAUDE_CODE_VERSION=latest
USER developer
RUN curl -fsSL https://claude.ai/install.sh | bash -s -- "${CLAUDE_CODE_VERSION}"
USER root
RUN cp -L /home/developer/.local/bin/claude /usr/local/bin/claude && \
    chmod 755 /usr/local/bin/claude && \
    rm -rf /home/developer/.local /home/developer/.claude /home/developer/.claude.json /home/developer/.cache && \
    /usr/local/bin/claude --version

# The binary lives in a root-owned location, so the auto-updater cannot replace it;
# update by rebuilding the image (CLAUDE_CODE_VERSION build arg) instead
ENV DISABLE_AUTOUPDATER=1

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 755 /usr/local/bin/entrypoint.sh

# Run as non-root for safety
USER developer
WORKDIR /home/developer

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
