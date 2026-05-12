FROM node:24-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
  git curl sudo less procps openssh-client jq python3-minimal \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

# Install GitHub CLI for HTTPS git auth (gh as credential helper)
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      -o /usr/share/keyrings/githubcli-archive-keyring.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list && \
    apt-get update && apt-get install -y --no-install-recommends gh && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Match host user's uid so mounted volumes are readable/writable
ARG HOST_UID=501
RUN usermod -u $HOST_UID node && \
    find /home/node -maxdepth 1 -not -path /home/node -exec chown -R node:node {} + 2>/dev/null; true

RUN mkdir -p /usr/local/share/npm-global && chown -R node:node /usr/local/share/npm-global

USER node
ENV NPM_CONFIG_PREFIX=/usr/local/share/npm-global
ENV PATH=$PATH:/usr/local/share/npm-global/bin

RUN npm install -g @anthropic-ai/claude-code@latest

RUN mkdir -p /home/node/.claude
WORKDIR /workspace

ENTRYPOINT ["claude"]
