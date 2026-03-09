# cc-yolo

Run Claude Code in a disposable Docker container with no permission prompts — and full access to your host session history.

## Install

Tell Claude:

> Read https://raw.githubusercontent.com/STRML/cc-yolo/main/yolo.md and install yolo on my machine.

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
