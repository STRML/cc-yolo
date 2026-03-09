function yolo-pull --description "Rebuild Claude Code Docker image with latest version"
    docker build --no-cache --build-arg HOST_UID=(id -u) -t claude-code ~/.claude/docker/
end
