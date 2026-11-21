# DevBridge

DevBridge is a local Windows helper that connects a normal ChatGPT browser session to local Git checkouts and build scripts.

## Current implementation status

The current prototype contains:
- PowerShell project preflight and build-cycle controller.
- Persistent Edge profile controlled by Playwright.
- A strict assistant command protocol.
- Git branch and clean-working-tree safety checks.
- Fast-forward-only updates and build log reporting.

The ChatGPT page selectors are UI-dependent. Test them manually before relying on unattended operation. DevBridge does not bypass sign-in, CAPTCHA, account controls, or browser security.

## Requirements

- Windows PowerShell 5.1 or later.
- Git installed and available on PATH.
- Node.js LTS and npm.
- Microsoft Edge installed.
- A local clone of the project with its target branch checked out and a clean working tree.

## First setup

1. Clone this repository.
2. Run `.Install.ps1` from PowerShell.
3. Copy `config/projects.example.json` to `config/projects.json`.
4. Edit the project path, branch, build command, arguments and working directory.
5. Run a preflight: `.DevBridge.ps1 -Project "Your project name" -CheckOnly`.
6. Run `.DevBridge.ps1 -Project "Your project name"`.
7. Sign in to ChatGPT in the opened Edge window if required. Start or open the intended conversation and give ChatGPT the development task.

The controller snapshots the currently visible last assistant message as its baseline. It deliberately ignores old commands. After startup, ChatGPT must produce a fresh command line.

## Assistant command protocol

Commands must appear as a standalone line in the LAST assistant message:

```text
DEVBRIDGE: BUILD
DEVBRIDGE: WAIT
DEVBRIDGE: DONE
DEVBRIDGE: ABORT
```

- `BUILD`: fetch the configured remote branch, fast-forward only, run the configured build, and send the build report into the same chat.
- `WAIT`: do not build; continue monitoring for a later assistant command.
- `DONE`: stop normally.
- `ABORT`: stop immediately.

A command in an older message, user message, quoted block or partial substring is not accepted. The last assistant message must stabilize across polling before processing.

## Safety behavior

- DevBridge never checks out or switches branches.
- It refuses to run if the current branch differs from the configured branch.
- It refuses to pull if the working tree is dirty.
- It never resets, rebases or force-pushes.
- It uses `git pull --ff-only`; diverged or locally-ahead histories stop the cycle.
- Build cycles are limited by `maxBuildCycles`.
- Browser/UI errors stop the process instead of guessing.

## Configuration

See `config/settings.json` and `config/projects.example.json`. Keep your actual `config/projects.json`, browser profile, logs and state local; they are excluded from Git.

## Known limitations

- Browser selectors can change when ChatGPT's UI changes.
- ChatGPT generation-complete detection is currently based on a stable last-message snapshot, not a guaranteed internal completion signal.
- Handoff/chat rotation is not yet implemented.
- The prototype has not yet been tested on the user's Windows machine or against their actual build scripts.
