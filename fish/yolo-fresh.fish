function yolo-fresh --description "Run Claude Code in Docker sandbox with clean state"
    docker run -it --rm \
        -v (pwd):/workspace -w /workspace \
        claude-code --dangerously-skip-permissions $argv
end
