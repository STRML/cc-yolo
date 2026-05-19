function yolo-fresh --description "Run Claude Code in Docker sandbox with clean state"
    docker run -it --rm \
        --cap-drop=ALL \
        --cap-add=NET_ADMIN --cap-add=NET_RAW \
        --cap-add=SETUID --cap-add=SETGID \
        --security-opt=no-new-privileges \
        --pids-limit 512 \
        -v (pwd):/workspace -w /workspace \
        claude-code --dangerously-skip-permissions $argv
end
