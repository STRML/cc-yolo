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

Verify `jq` is on PATH (used by the shell functions to patch `~/.claude.json` and parse plugin marketplaces):
```sh
command -v jq
```
If missing, tell the user to install it (`brew install jq` on macOS, `apt install jq` on Debian/Ubuntu) and stop.

Detect the user's shell:
```sh
echo $SHELL
```

### 2. Write the Dockerfile and entrypoint scripts

Write three files to `~/.claude/docker/`.

**`~/.claude/docker/Dockerfile`** (keep in sync with the `Dockerfile` at the repo root)
```dockerfile
FROM node:24-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
  git curl sudo less procps openssh-client jq python3-minimal \
  iptables ipset dnsutils gosu \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

# Install GitHub CLI for HTTPS git auth (gh as credential helper)
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      -o /usr/share/keyrings/githubcli-archive-keyring.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list && \
    apt-get update && apt-get install -y --no-install-recommends gh && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

ARG HOST_UID=501
RUN usermod -u $HOST_UID node && \
    find /home/node -maxdepth 1 -not -path /home/node -exec chown -R node:node {} + 2>/dev/null; true

RUN mkdir -p /usr/local/share/npm-global && chown -R node:node /usr/local/share/npm-global

ENV NPM_CONFIG_PREFIX=/usr/local/share/npm-global
ENV PATH=$PATH:/usr/local/share/npm-global/bin

USER node
RUN npm install -g @anthropic-ai/claude-code@latest && mkdir -p /home/node/.claude

USER root
COPY --chmod=755 init-firewall.sh /usr/local/bin/init-firewall.sh
COPY --chmod=755 entrypoint.sh    /usr/local/bin/entrypoint.sh

WORKDIR /workspace

# Entrypoint runs as root, configures the egress allowlist via iptables,
# then drops to the `node` user before exec'ing claude. Requires the
# container to be launched with --cap-add=NET_ADMIN --cap-add=NET_RAW.
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["--help"]
```

**`~/.claude/docker/init-firewall.sh`** — copy verbatim from [`init-firewall.sh`](./init-firewall.sh) in this repo. Restricts outbound traffic to npm, pypi, GitHub, Anthropic API, and a few other essentials. Set `YOLO_NO_FIREWALL=1` in the environment to bypass (debugging only).

**`~/.claude/docker/entrypoint.sh`** — copy verbatim from [`entrypoint.sh`](./entrypoint.sh) in this repo. Runs the firewall as root then drops to the `node` user via gosu.

Make both scripts executable: `chmod +x ~/.claude/docker/init-firewall.sh ~/.claude/docker/entrypoint.sh`

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

    # Plugins: mount local marketplace directories so plugins from forks/dev installs load
    set -l known_mktplaces "$HOME/.claude/plugins/known_marketplaces.json"
    if test -f "$known_mktplaces"
        for dir in (python3 -c "
import json, sys
try:
    with open(sys.argv[1]) as f: d = json.load(f)
except Exception: sys.exit(0)
for v in d.values():
    if isinstance(v, dict):
        s = v.get('source', {})
        if s.get('source') == 'directory' and s.get('path'):
            print(s['path'])
" "$known_mktplaces" 2>/dev/null)
            if test -d "$dir"
                set -a vols -v "$dir:$dir:ro"
            end
        end
    end

    # Git: mount config, SSH, and gh credentials
    if test -f "$HOME/.gitconfig"
        set -a vols -v "$HOME/.gitconfig:$HOME/.gitconfig:ro"
    end
    if test -d "$HOME/.ssh"
        set -a vols -v "$HOME/.ssh:$HOME/.ssh:ro"
    end
    if test -d "$HOME/.config/gh"
        set -a vols -v "$HOME/.config/gh:$HOME/.config/gh:ro"
    end
    # SSH agent forwarding (Docker Desktop macOS, or native socket)
    if test -S /run/host-services/ssh-auth.sock
        set -a vols \
            -v /run/host-services/ssh-auth.sock:/run/host-services/ssh-auth.sock \
            -e SSH_AUTH_SOCK=/run/host-services/ssh-auth.sock
    else if test -n "$SSH_AUTH_SOCK"
        set -a vols \
            -v "$SSH_AUTH_SOCK:$SSH_AUTH_SOCK" \
            -e SSH_AUTH_SOCK="$SSH_AUTH_SOCK"
    end

    # Hardening: drop every cap, re-add the two needed by the firewall,
    # forbid privilege escalation, cap process count.
    set -l sec \
        --cap-drop=ALL --cap-add=NET_ADMIN --cap-add=NET_RAW \
        --security-opt=no-new-privileges \
        --pids-limit 512

    docker run -it --rm $sec $vols $img --dangerously-skip-permissions $argv

    rm -f $patched
end
```

**`~/.config/fish/functions/yolo-fresh.fish`**
```fish
function yolo-fresh --description "Run Claude Code in Docker sandbox with clean state"
    docker run -it --rm \
        --cap-drop=ALL --cap-add=NET_ADMIN --cap-add=NET_RAW \
        --security-opt=no-new-privileges \
        --pids-limit 512 \
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
    local jq_filter='.hasCompletedOnboarding = true | (.theme //= "dark") | (.projects[$proj].hasTrustDialogAccepted = true)'
    # If the host file is missing or unparseable, fall back to {}.
    jq --arg proj "$(pwd)" "$jq_filter" "$HOME/.claude.json" >"$patched" 2>/dev/null \
        || echo '{}' | jq --arg proj "$(pwd)" "$jq_filter" >"$patched"

    # Plugins: mount local marketplace directories so plugins from forks/dev installs load
    local plugin_vols=()
    local known_mktplaces="$HOME/.claude/plugins/known_marketplaces.json"
    if [ -f "$known_mktplaces" ]; then
        while IFS= read -r dir; do
            [ -d "$dir" ] && plugin_vols+=(-v "$dir:$dir:ro")
        done < <(jq -r '.[] | select(type == "object") | .source | select(.source == "directory") | .path // empty' "$known_mktplaces" 2>/dev/null)
    fi

    local git_vols=()
    [ -f "$HOME/.gitconfig" ] && git_vols+=(-v "$HOME/.gitconfig:$HOME/.gitconfig:ro")
    [ -d "$HOME/.ssh" ] && git_vols+=(-v "$HOME/.ssh:$HOME/.ssh:ro")
    [ -d "$HOME/.config/gh" ] && git_vols+=(-v "$HOME/.config/gh:$HOME/.config/gh:ro")
    # SSH agent forwarding (Docker Desktop macOS, or native socket)
    if [ -S /run/host-services/ssh-auth.sock ]; then
        git_vols+=(-v /run/host-services/ssh-auth.sock:/run/host-services/ssh-auth.sock)
        git_vols+=(-e SSH_AUTH_SOCK=/run/host-services/ssh-auth.sock)
    elif [ -n "$SSH_AUTH_SOCK" ]; then
        git_vols+=(-v "$SSH_AUTH_SOCK:$SSH_AUTH_SOCK")
        git_vols+=(-e "SSH_AUTH_SOCK=$SSH_AUTH_SOCK")
    fi

    # NET_ADMIN/NET_RAW are needed by init-firewall.sh; both become
    # inert after gosu drops to the node user.
    local sec=(
        --cap-drop=ALL --cap-add=NET_ADMIN --cap-add=NET_RAW
        --security-opt=no-new-privileges
        --pids-limit 512
    )

    docker run -it --rm \
        "${sec[@]}" \
        -v "$(pwd):$(pwd)" -w "$(pwd)" \
        -v "$HOME/.claude:$HOME/.claude" \
        -v "$patched:$HOME/.claude.json" \
        -e "HOME=$HOME" \
        -e "TERM=$TERM" \
        "${plugin_vols[@]}" \
        "${git_vols[@]}" \
        "$img" --dangerously-skip-permissions "$@"

    rm -f "$patched"
}

yolo-fresh() {
    docker run -it --rm \
        --cap-drop=ALL --cap-add=NET_ADMIN --cap-add=NET_RAW \
        --security-opt=no-new-privileges \
        --pids-limit 512 \
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

## Network egress

The container starts as root, runs `init-firewall.sh` to install an iptables
allowlist, then drops to the `node` user via gosu before `claude` is exec'd.
By default outbound traffic is permitted only to:

- `registry.npmjs.org`, `registry.yarnpkg.com`
- `pypi.org`, `files.pythonhosted.org`
- All GitHub IP ranges (web, api, git) via `api.github.com/meta`
- `api.anthropic.com`, `statsig.anthropic.com`, `statsig.com`, `sentry.io`
- `cli.github.com`, `objects.githubusercontent.com`
- DNS (UDP/53) and SSH (TCP/22)
- The host LAN /24 (so SSH agent forwarding works on Docker Desktop)

Everything else is REJECTed at the firewall, so a malicious postinstall
script can't exfiltrate secrets to attacker-controlled domains.

To temporarily extend the allowlist for one session, pass a space-separated
list via `YOLO_EXTRA_DOMAINS`:

```sh
docker run … -e YOLO_EXTRA_DOMAINS="deb.debian.org security.debian.org" …
```

To skip the firewall entirely (debugging only), set `YOLO_NO_FIREWALL=1`.

## Plugins and skills

Plugins installed from local directories (forks, dev installs) reference host paths that aren't available in the container by default. The shell functions automatically parse `~/.claude/plugins/known_marketplaces.json` and mount any local marketplace directories read-only into the container. This means your fork-based plugins and their skills work without extra configuration.

The Dockerfile also includes `jq` and `python3` since many plugin hooks depend on them.

## Git authentication

The shell functions automatically mount `~/.gitconfig`, `~/.ssh`, and `~/.config/gh` (if they exist) into the container, so git pushes work out of the box.

**SSH remotes**: The functions forward your SSH agent into the container. On Docker Desktop for macOS this uses `/run/host-services/ssh-auth.sock`; on Linux it forwards `$SSH_AUTH_SOCK` directly. Make sure your key is loaded (`ssh-add -l`).

**HTTPS remotes (GitHub)**: If you use `gh` as your git credential helper (`gh auth setup-git`), it works automatically since both `gh` and `~/.config/gh` are available in the container.

## Note on macOS Keychain

The credential extraction step (`security find-generic-password`) is macOS-only. On Linux, remove those lines — Claude Code will authenticate via its normal OAuth flow on first run and cache credentials in `~/.claude/.credentials.json` itself.
