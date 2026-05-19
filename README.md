# cc-yolo

Run Claude Code in a disposable Docker container with no permission prompts — and full access to your host session history.

## Install

Tell Claude:

> Read https://raw.githubusercontent.com/STRML/cc-yolo/main/yolo.md and install yolo on my machine.

## Usage

```sh
yolo                        # new session in current directory
yolo --resume <uuid>        # resume a previous session
yolo-incognito              # disposable container, no host state mounted
yolo-pull                   # rebuild image with latest claude-code
```

## Security model

The container is hardened against the npm/pypi supply-chain threat (malicious postinstall scripts running with your credentials and exfiltrating to attacker infrastructure):

- **Egress allowlist** — `init-firewall.sh` runs at container start and restricts outbound traffic via iptables/ipset to npm, pypi, GitHub, Anthropic API, and a handful of essentials. Everything else is REJECTed. Bypass with `YOLO_NO_FIREWALL=1` for debugging; extend with `YOLO_EXTRA_DOMAINS="..."`.
- **Capability dropping** — `--cap-drop=ALL` then `--cap-add=NET_ADMIN --cap-add=NET_RAW` for the firewall init only. Caps become inert once gosu drops to the `node` user.
- **No privilege escalation** — `--security-opt=no-new-privileges` blocks setuid binaries from gaining extra perms.
- **Process limit** — `--pids-limit 512` caps fork-bomb / runaway behavior.
- **Read-only secret mounts** — `~/.ssh`, `~/.gitconfig`, `~/.config/gh` mounted `:ro` so a compromised container can't tamper with them.

What this **doesn't** protect against:

- **Secrets at rest are still readable.** Read-only mounts stop tampering, not reading. A malicious script can still read `~/.ssh/id_ed25519`; the firewall is what prevents exfiltration. Passphrase-protect your SSH keys; use scoped fine-grained PATs in `~/.config/gh`; consider a separate Anthropic API key with a low spend cap for yolo sessions.
- **Workspace tampering.** Your project mount is read-write — by design, since Claude needs to edit code — but malware can plant backdoors there. Review diffs before pushing.
- **SSH agent forwarding is on by default** when an agent socket is detected. While forwarded, anything in the container can authenticate as you to any host your key reaches. If that worries you, prefer HTTPS via `gh` and unset `SSH_AUTH_SOCK` before running yolo.

Recommended extras (not done automatically since they affect every project):

- `npm config set ignore-scripts true` on your host, opted-in per-package when needed — closes the most common postinstall vector before yolo even matters.
- Use 1Password / `op-cli` for cloud creds instead of plaintext `~/.aws/credentials` so they aren't readable from any sandbox.

## How session resuming works

Claude Code stores conversation history as `<uuid>.jsonl` under `~/.claude/projects/<slugified-path>/`. The slug is derived from the **absolute path** of the working directory.

`yolo` mounts your project at its real host path (e.g. `/Users/you/code/myproject`) rather than `/workspace`, so the slug inside the container is identical to the one written on your host. This means `--resume <uuid>` finds sessions from both environments.
