# DevBridge

DevBridge connects a ChatGPT browser session to local Git checkouts and build scripts. ChatGPT's GitHub integration edits source; DevBridge uses local Git commands and runs the configured build. No GitHub token is used.

## Requirements
- Windows 10/11, Windows PowerShell 5.1, Git, Node.js LTS and npm.
- Yandex Browser (or another Chromium executable configured in config/settings.json).
- Local project clone with the configured branch checked out.

## Setup
1. Run .\Install.ps1.
2. Configure config/projects.json with repository path, exact branch and build command.
3. Run .\Test-DevBridge.ps1 to check PowerShell, JavaScript and JSON syntax locally.
4. Run .\DevBridge.ps1 -Project "Your project name" -CheckOnly.
5. Test with .\DevBridge.ps1 -Project "Your project name".
6. DevBridge launches the configured browser with a dedicated persistent profile in browser-profile. Sign in to ChatGPT manually once in that profile. It never automates passwords, CAPTCHA or MFA.
7. Enable background startup at Windows sign-in with .\Install-Autostart.ps1. If more than one project is configured, specify it explicitly, for example .\Install-Autostart.ps1 -Project "Android 5.1.1". The task runs as the signed-in user, with a hidden PowerShell window; the browser remains visible.
8. Remove startup with .\Install-Autostart.ps1 -Uninstall.

The dedicated browser profile is separate from your everyday browser profile, so it does not interfere with an already-running normal Yandex session.

## Monitoring
- Starts without pressing Enter.
- Follows the focused ChatGPT tab; if focus moves outside ChatGPT, it retains the last selected ChatGPT tab.
- Stores per-conversation message hashes in state/monitor-state.json. A newly encountered conversation is baselined, so old commands are not replayed.
- On restart, the currently visible last message is baselined to avoid replaying a command after a crash or reboot.
- Build reports and safety feedback are sent to the same conversation that issued the command.
- Handoff continues in a new conversation in the same browser tab.

## Commands
The final line of the last assistant message must be one of:
    DEVBRIDGE: BUILD READY
    DEVBRIDGE: WAIT
    DEVBRIDGE: DONE
    DEVBRIDGE: ABORT

BUILD READY (legacy BUILD accepted) fetches the configured branch, fast-forwards only, builds once for the commit batch and reports to the originating chat. WAIT keeps monitoring. DONE stops only when the latest remote commit is exactly the successfully built commit. ABORT stops immediately.

## Git safety
DevBridge never switches branches, refuses dirty working trees, uses git pull --ff-only, and never resets, rebases or force-pushes. Diverged/local-ahead histories stop safely.

## Configuration
See config/settings.json and config/projects.example.json. Actual projects config, browser profile, logs and state remain local and are ignored by Git. Optional versionSource supports incrementing a version from an HTTPS JSON manifest before build.

## Limitations
ChatGPT selectors and browser focus detection depend on the current UI/browser. Generation completion is inferred from a stable message snapshot. Handoff uses visible character count rather than tokens. Test the workflow before unattended use.
