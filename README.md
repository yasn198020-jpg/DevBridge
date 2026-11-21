# DevBridge

DevBridge is a local Windows helper that connects a normal ChatGPT browser session to local Git checkouts and build scripts. ChatGPT's existing GitHub integration performs source edits; DevBridge only uses ordinary local Git commands (`fetch` and fast-forward-only `pull`). It does not use GitHub API credentials or tokens.

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
2. Run `.\Install.ps1` from PowerShell.
3. The installer creates `config/projects.json` from the example if it does not exist.
4. Edit the project path, branch, build command, arguments and working directory.
5. Run a preflight: `.\DevBridge.ps1 -Project "Your project name" -CheckOnly`.
6. Run `.\DevBridge.ps1 -Project "Your project name"`.
7. Alternatively, start the monitor with `Run-DevBridge.cmd -Project "Your project name"`.
8. Sign in to ChatGPT in the opened Edge window if required, then open the intended conversation.
9. Return to the PowerShell window and press Enter. DevBridge captures the current message as a baseline, so old commands in the chat will not run. Now give ChatGPT the development task.

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
- `DONE`: stop only if the latest remote branch commit is exactly the commit that passed the local build.
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

### Automatic build version

A project may define an optional `versionSource` object:
- `url`: HTTPS URL of a published JSON version manifest (for example, the channel's `version.json`).
- `field`: numeric field containing the currently published version.
- `increment`: amount to add (normally `1`).
- `minimum`: lowest accepted published version.
- `placeholder`: token that must appear exactly once in `buildArguments`, such as `{VERSION_CODE}`.

Before a build, DevBridge reads the manifest, validates the current version, adds the increment, and substitutes the placeholder in the build arguments. If the manifest cannot be read or validated, the build is stopped. `-CheckOnly` performs the same version lookup and argument validation but never starts a build. A failed build does not consume a version; the next attempt will calculate from the latest successfully published manifest.

## Known limitations

- Browser selectors can change when ChatGPT's UI changes.
- ChatGPT generation-complete detection is based on a stable last-message snapshot, not a guaranteed internal completion signal.
- Long-chat handoff is triggered by an approximate character count of message text visible in the page. It is not a token counter and cannot see hidden system context or attachments.
- Handoff opens a new chat only after receiving the required summary marker and verifying that the new conversation is blank. UI changes can still interrupt this process.
- The prototype has not yet been tested on the user's Windows machine or against their actual build scripts.
