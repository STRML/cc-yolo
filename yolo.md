# yolo — Claude Code in Docker

Run Claude Code in a disposable Docker sandbox with no permission prompts and full access to your host session history, including `--resume <uuid>`.

## Install

Tell Claude:

> Read https://raw.githubusercontent.com/STRML/cc-yolo/main/yolo.md and install yolo on my machine.

## Agent Installation Instructions

You are installing the `yolo` Docker sandbox for Claude Code. Perform all steps below.

### 1. Prerequisites

Verify Docker is installed and running:
```sh
docker info
```
If Docker is missing, tell the user to install it and stop.

Detect the user's shell:
```sh
echo $SHELL
```

### 2. Write the Dockerfile

Write this file to `~/.claude/docker/Dockerfile`:

```dockerfile
FROM node:24-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
  git curl sudo less procps \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

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
```

### 3. Write the shell functions

Install the appropriate version for the user's shell.

---

#### fish (`~/.config/fish/functions/`)

**`~/.config/fish/functions/yolo.fish`**
```fish
function yolo --description "Run Claude Code in Docker sandbox with no permissions prompts"
    set -l img claude-code

    set -l creds (security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null)
    if test -n "$creds"
        echo $creds > "$HOME/.claude/.credentials.json"
        chmod 600 "$HOME/.claude/.credentials.json"
    end

    set -l patched (mktemp)
    python3 -c "
import json, sys
src, dst = sys.argv[1], sys.argv[2]
try:
    with open(src) as f: d = json.load(f)
except (json.JSONDecodeError, FileNotFoundError):
    d = {}
d['hasCompletedOnboarding'] = True
d.setdefault('theme', 'dark')
d.setdefault('projects', {}).setdefault(sys.argv[3], {})['hasTrustDialogAccepted'] = True
with open(dst, 'w') as f: json.dump(d, f, indent=2)
" "$HOME/.claude.json" "$patched" (pwd)

    set -l vols \
        -v (pwd):(pwd) -w (pwd) \
        -v "$HOME/.claude:$HOME/.claude" \
        -v "$patched:$HOME/.claude.json" \
        -e "HOME=$HOME" \
        -e "TERM=$TERM"

    docker run -it --rm $vols $img --dangerously-skip-permissions $argv

    rm -f $patched
end
```

**`~/.config/fish/functions/yolo-fresh.fish`**
```fish
function yolo-fresh --description "Run Claude Code in Docker sandbox with clean state"
    docker run -it --rm \
        -v (pwd):/workspace -w /workspace \
        claude-code --dangerously-skip-permissions $argv
end
```

**`~/.config/fish/functions/yolo-pull.fish`**
```fish
function yolo-pull --description "Rebuild Claude Code Docker image with latest version"
    docker build --no-cache --build-arg HOST_UID=(id -u) -t claude-code ~/.claude/docker/
end
```

After writing, reload: `source ~/.config/fish/functions/yolo.fish`

---

#### bash / zsh (`~/.bashrc` or `~/.zshrc`)

Append these functions to the user's rc file (`~/.bashrc` for bash, `~/.zshrc` for zsh):

```sh
yolo() {
    local img=claude-code
    local creds
    creds=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null)
    if [ -n "$creds" ]; then
        echo "$creds" > "$HOME/.claude/.credentials.json"
        chmod 600 "$HOME/.claude/.credentials.json"
    fi

    local patched
    patched=$(mktemp)
    python3 -c "
import json, sys
src, dst = sys.argv[1], sys.argv[2]
try:
    with open(src) as f: d = json.load(f)
except (json.JSONDecodeError, FileNotFoundError):
    d = {}
d['hasCompletedOnboarding'] = True
d.setdefault('theme', 'dark')
d.setdefault('projects', {}).setdefault(sys.argv[3], {})['hasTrustDialogAccepted'] = True
with open(dst, 'w') as f: json.dump(d, f, indent=2)
" "$HOME/.claude.json" "$patched" "$(pwd)"

    docker run -it --rm \
        -v "$(pwd):$(pwd)" -w "$(pwd)" \
        -v "$HOME/.claude:$HOME/.claude" \
        -v "$patched:$HOME/.claude.json" \
        -e "HOME=$HOME" \
        -e "TERM=$TERM" \
        "$img" --dangerously-skip-permissions "$@"

    rm -f "$patched"
}

yolo-fresh() {
    docker run -it --rm \
        -v "$(pwd):/workspace" -w /workspace \
        claude-code --dangerously-skip-permissions "$@"
}

yolo-pull() {
    docker build --no-cache --build-arg HOST_UID="$(id -u)" -t claude-code ~/.claude/docker/
}
```

After writing, reload: `source ~/.bashrc` (or `~/.zshrc`).

---

### 4. Build the Docker image

```sh
docker build --build-arg HOST_UID=$(id -u) -t claude-code ~/.claude/docker/
```

This will take a minute — it installs `@anthropic-ai/claude-code` from npm.

### 5. (Optional) Skip the dangerous mode confirmation

Add to `~/.claude/settings.json`:
```json
{
  "skipDangerousModePermissionPrompt": true
}
```

### 6. Verify

Run from any project directory:
```sh
yolo --version
```

You should see the Claude Code version printed from inside the container. Installation is complete.

---

## Usage

```sh
yolo                        # new session in current directory
yolo --resume <uuid>        # resume a previous session
yolo-fresh                  # clean container, no ~/.claude mounted
yolo-pull                   # rebuild image with latest claude-code
```

## How session resuming works

Claude Code stores conversation history as `<uuid>.jsonl` under `~/.claude/projects/<slugified-path>/`. The slug is derived from the **absolute path** of the working directory.

`yolo` mounts your project at its real host path (e.g. `/Users/you/code/myproject`) rather than `/workspace`, so the slug inside the container is identical to the one written on your host. This means `--resume <uuid>` finds sessions from both environments.

## Note on macOS Keychain

The credential extraction step (`security find-generic-password`) is macOS-only. On Linux, remove those lines — Claude Code will authenticate via its normal OAuth flow on first run and cache credentials in `~/.claude/.credentials.json` itself.
