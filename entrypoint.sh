#!/bin/bash
# Container entrypoint: configure firewall as root, then drop to `node`
# and exec claude. Lives in /usr/local/bin inside the image.
set -e

if [ -z "${YOLO_NO_FIREWALL:-}" ]; then
    /usr/local/bin/init-firewall.sh
else
    echo "yolo: YOLO_NO_FIREWALL=1 set — outbound is unrestricted" >&2
fi

# gosu drops uid/gid + supplementary groups + capabilities cleanly.
exec gosu node claude "$@"
