FROM node:24-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
  git curl sudo less procps \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

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
