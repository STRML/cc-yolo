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
    set -l jq_filter '.hasCompletedOnboarding = true | (.theme //= "dark") | (.projects[$proj].hasTrustDialogAccepted = true)'
    # If the host file is missing or unparseable, fall back to {}.
    jq --arg proj (pwd) "$jq_filter" "$HOME/.claude.json" >$patched 2>/dev/null
    or echo '{}' | jq --arg proj (pwd) "$jq_filter" >$patched

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
        for dir in (jq -r '.[] | select(type == "object") | .source | select(.source == "directory") | .path // empty' "$known_mktplaces" 2>/dev/null)
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

    # Security hardening: drop every capability, add back the four needed:
    # NET_ADMIN/NET_RAW for init-firewall.sh's iptables config, and
    # SETUID/SETGID so gosu can drop privileges to `node` afterwards.
    # All four become inert when the child exec'd by gosu runs as a
    # non-root uid.
    set -l sec \
        --cap-drop=ALL \
        --cap-add=NET_ADMIN --cap-add=NET_RAW \
        --cap-add=SETUID --cap-add=SETGID \
        --security-opt=no-new-privileges \
        --pids-limit 512

    docker run -it --rm $sec $vols $img --dangerously-skip-permissions $argv

    rm -f $patched
end
