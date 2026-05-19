#!/bin/bash
# Egress allowlist for the yolo container.
#
# Adapted from anthropics/claude-code .devcontainer/init-firewall.sh.
# Runs as root at container start, then privileges are dropped to `node`
# by entrypoint.sh. The container is launched with --cap-drop=ALL plus
# --cap-add=NET_ADMIN --cap-add=NET_RAW so this script can configure
# iptables; those caps become inert once we drop to a non-root user.
#
# Set YOLO_NO_FIREWALL=1 to skip (only useful for debugging).
set -euo pipefail
IFS=$'\n\t'

# Preserve Docker's internal DNS NAT rules (127.0.0.11) across our flush.
DOCKER_DNS_RULES=$(iptables-save -t nat | grep "127\.0\.0\.11" || true)

iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
iptables -t mangle -F
iptables -t mangle -X
ipset destroy allowed-domains 2>/dev/null || true

if [ -n "$DOCKER_DNS_RULES" ]; then
    iptables -t nat -N DOCKER_OUTPUT 2>/dev/null || true
    iptables -t nat -N DOCKER_POSTROUTING 2>/dev/null || true
    echo "$DOCKER_DNS_RULES" | xargs -L 1 iptables -t nat
fi

# Allow DNS (UDP + TCP for truncated responses), SSH, and localhost
# before policy flip.
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A INPUT  -p udp --sport 53 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT
iptables -A INPUT  -p tcp --sport 53 -m state --state ESTABLISHED -j ACCEPT
iptables -A OUTPUT -p tcp --dport 22 -j ACCEPT
iptables -A INPUT  -p tcp --sport 22 -m state --state ESTABLISHED -j ACCEPT
iptables -A INPUT  -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

ipset create allowed-domains hash:net

# GitHub publishes its full CIDR list at /meta — much more reliable than
# resolving a few hostnames since git-over-https hits a different pool.
echo "Fetching GitHub IP ranges..."
gh_ranges=$(curl -s https://api.github.com/meta)
if [ -z "$gh_ranges" ] || ! echo "$gh_ranges" | jq -e '.web and .api and .git' >/dev/null; then
    echo "ERROR: failed to fetch or parse GitHub meta"
    exit 1
fi
# /meta returns IPv4 + IPv6 CIDRs; the ipset is hash:net (IPv4) so the
# jq filter drops IPv6. sort -u dedupes; ipset silently rejects exact
# duplicates so we add || true.
while read -r cidr; do
    [[ "$cidr" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]] || {
        echo "ERROR: invalid IPv4 CIDR from GitHub meta: $cidr"; exit 1; }
    ipset add allowed-domains "$cidr" 2>/dev/null || true
done < <(echo "$gh_ranges" | jq -r '(.web + .api + .git)[] | select(test("^[0-9.]+/[0-9]+$"))' | sort -u)

# Resolve and pin every domain we want to reach.
# Extra domains can be appended via YOLO_EXTRA_DOMAINS="foo.com bar.com".
# SYNC: keep the "Network egress" section in yolo.md aligned with this list.
domains=(
    "registry.npmjs.org"
    "registry.yarnpkg.com"
    "pypi.org"
    "files.pythonhosted.org"
    "api.anthropic.com"
    "statsig.anthropic.com"
    "statsig.com"
    "sentry.io"
    "cli.github.com"
    "objects.githubusercontent.com"
)
if [ -n "${YOLO_EXTRA_DOMAINS:-}" ]; then
    # Top-level IFS is "\n\t" so a bare `for d in $VAR` won't split on
    # spaces. Use read -ra with default IFS for the documented
    # space-separated format.
    IFS=' ' read -ra _extra <<< "${YOLO_EXTRA_DOMAINS}"
    domains+=("${_extra[@]}")
fi
# Resolve in parallel — sequential dig is the dominant startup cost.
# Each subshell captures its own $i and writes to its own file so we
# don't worry about interleaved appends.
tmpdir=$(mktemp -d)
i=0
for domain in "${domains[@]}"; do
    (
        ips=$(dig +short A "$domain" | awk '$1 ~ /^[0-9.]+$/ {print}')
        if [ -z "$ips" ]; then
            echo "WARN: failed to resolve $domain, skipping" >&2
        else
            printf '%s\n' "$ips" > "$tmpdir/$i.ips"
        fi
    ) &
    i=$((i + 1))
done
wait
if compgen -G "$tmpdir/*.ips" >/dev/null; then
    while read -r ip; do
        [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || continue
        ipset add allowed-domains "$ip" 2>/dev/null || true
    done < <(cat "$tmpdir"/*.ips)
fi
rm -rf "$tmpdir"

# Allow the host network so SSH agent forwarding and `host.docker.internal`
# still work for Docker Desktop on macOS.
HOST_IP=$(ip route | awk '/^default/ {print $3; exit}')
if [ -n "$HOST_IP" ]; then
    HOST_NETWORK=$(echo "$HOST_IP" | sed "s/\.[0-9]*$/.0\/24/")
    iptables -A INPUT  -s "$HOST_NETWORK" -j ACCEPT
    iptables -A OUTPUT -d "$HOST_NETWORK" -j ACCEPT
fi

# Default DROP; allow established + allowlisted; REJECT the rest so
# blocked traffic fails fast instead of timing out.
iptables -P INPUT  DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP
iptables -A INPUT  -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m set --match-set allowed-domains dst -j ACCEPT
iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited

# Sanity checks.
if curl --connect-timeout 3 -s -o /dev/null https://example.com; then
    echo "ERROR: firewall verification failed — example.com is reachable"
    exit 1
fi
if ! curl --connect-timeout 5 -s -o /dev/null https://api.github.com/zen; then
    echo "ERROR: firewall verification failed — api.github.com is unreachable"
    exit 1
fi
echo "Firewall ready: outbound restricted to npm/pypi/github/anthropic + extras"
