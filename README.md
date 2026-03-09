# cc-yolo

Run Claude Code in a disposable Docker container with no permission prompts — and full access to your host session history.

## What it does

- Launches Claude Code inside an ephemeral Docker container (`--rm`)
- Skips all permission dialogs (`--dangerously-skip-permissions`)
- Shares your `~/.claude` directory at the **same absolute path** so plugins, skills, and settings resolve correctly
- Mounts your project at its **real host path** (not `/workspace`) so `--resume <uuid>` can find sessions created outside the container
- Pulls fresh OAuth credentials from macOS Keychain before each run

## Setup

### 1. Build the image

Copy `Dockerfile` to `~/.claude/docker/Dockerfile`, then:

```sh
docker build --build-arg HOST_UID=$(id -u) -t claude-code ~/.claude/docker/
```

Or use the included `yolo-pull` function to do this in one command.

### 2. Install fish functions

Copy the three fish functions to your functions directory:

```sh
cp fish/*.fish ~/.config/fish/functions/
```

### 3. (Optional) Skip the dangerous mode confirmation

Add to `~/.claude/settings.json`:

```json
{
  "skipDangerousModePermissionPrompt": true
}
```

## Usage

```sh
# Start a new session in the current directory
yolo

# Resume a previous session by UUID
yolo --resume <uuid>

# Pass any claude flags through
yolo --model claude-opus-4-5

# Start with a clean container (no ~/.claude mounted)
yolo-fresh

# Rebuild the image with the latest Claude Code version
yolo-pull
```

## Functions

### `yolo`

The main function. Mounts `~/.claude` and your project directory, patches `.claude.json` to skip onboarding dialogs, and injects fresh OAuth credentials from Keychain. All arguments are forwarded to `claude`.

### `yolo-fresh`

Runs a completely clean container — no `~/.claude` mount, no credentials, no history. Useful for testing behavior in a pristine environment.

### `yolo-pull`

Rebuilds the `claude-code` Docker image with the latest `@anthropic-ai/claude-code` from npm.

## How session resuming works

Claude Code stores conversation history as `<uuid>.jsonl` files under `~/.claude/projects/<slugified-path>/`. The slug is derived from the working directory's absolute path.

Previous setups mounted the project at `/workspace`, so Docker sessions got a different slug than host sessions — making `--resume` unable to find them. This setup mounts the project at its real path (e.g. `/Users/you/code/myproject`) so the slugs match and `--resume` works across both environments.

## Requirements

- macOS (uses Keychain for credentials)
- Docker
- fish shell
- Python 3 (pre-installed on macOS)
