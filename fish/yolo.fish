function yolo --description "Run Claude Code in Docker sandbox with no permissions prompts"
    set -l img claude-code

    # Pull fresh OAuth credentials from macOS Keychain into .credentials.json
    set -l creds (security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null)
    if test -n "$creds"
        echo $creds > "$HOME/.claude/.credentials.json"
        chmod 600 "$HOME/.claude/.credentials.json"
    end

    # Create a patched COPY of .claude.json for the container
    # Never modify the host file — Claude Code writes to it concurrently
    set -l patched (mktemp)
    python3 -c "
import json, sys, shutil
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

    # Mount project at its REAL path (not /workspace) so session slugs match
    # the host — required for --resume <uuid> to find the right .jsonl files
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

    # Git: mount config and forward SSH agent (Docker Desktop macOS)
    if test -f "$HOME/.gitconfig"
        set -a vols -v "$HOME/.gitconfig:$HOME/.gitconfig:ro"
    end
    if test -d "$HOME/.ssh"
        set -a vols -v "$HOME/.ssh:$HOME/.ssh:ro"
    end
    if test -d "$HOME/.config/gh"
        set -a vols -v "$HOME/.config/gh:$HOME/.config/gh:ro"
    end
    if test -S /run/host-services/ssh-auth.sock
        set -a vols \
            -v /run/host-services/ssh-auth.sock:/run/host-services/ssh-auth.sock \
            -e SSH_AUTH_SOCK=/run/host-services/ssh-auth.sock
    else if test -n "$SSH_AUTH_SOCK"
        set -a vols \
            -v "$SSH_AUTH_SOCK:$SSH_AUTH_SOCK" \
            -e SSH_AUTH_SOCK="$SSH_AUTH_SOCK"
    end

    # Security hardening: drop every capability, add back the two needed
    # by init-firewall.sh to configure iptables, and forbid privilege
    # escalation. The container starts as root only long enough to set
    # up the egress allowlist, then drops to `node` via gosu.
    set -l sec \
        --cap-drop=ALL --cap-add=NET_ADMIN --cap-add=NET_RAW \
        --security-opt=no-new-privileges \
        --pids-limit 512

    docker run -it --rm $sec $vols $img --dangerously-skip-permissions $argv

    rm -f $patched
end
