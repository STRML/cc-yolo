FROM node:24-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
  git curl sudo less procps openssh-client jq python3-minimal \
  iptables ipset dnsutils aggregate gosu \
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

ENV NPM_CONFIG_PREFIX=/usr/local/share/npm-global
ENV PATH=$PATH:/usr/local/share/npm-global/bin

USER node
RUN npm install -g @anthropic-ai/claude-code@latest
RUN mkdir -p /home/node/.claude

USER root
COPY init-firewall.sh /usr/local/bin/init-firewall.sh
COPY entrypoint.sh    /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/init-firewall.sh /usr/local/bin/entrypoint.sh

WORKDIR /workspace

# Entrypoint runs as root, configures the egress allowlist via iptables,
# then drops to the `node` user before exec'ing claude. Requires the
# container to be launched with --cap-add=NET_ADMIN --cap-add=NET_RAW.
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
