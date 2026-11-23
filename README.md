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

## Desktop dashboard
- Run `.\Install-Desktop-Dashboard.ps1` once to create `DevBridge — мониторинг` on the Windows desktop.
- Open the shortcut to show the live status and recent log. Use **Запустить отслеживание** to start the configured Android 5.1.1 monitor and **Остановить** to request a safe stop.
- Closing the dashboard leaves monitoring running; use the Stop button to stop it.

## Monitoring
- Starts without pressing Enter.
- Polls `origin/<configured-branch>` every 20 seconds by default (configurable with `automation.gitPollIntervalSeconds`). A newly pushed commit is fetched automatically; no ChatGPT command is required.
- Before an automatic build, waits for the remote HEAD to remain unchanged for 6 seconds, checking every 2 seconds. If commits A and B arrive during this quiet window, the timer restarts and only the latest state (B) is built. A final fetch inside the build path also picks up a push that lands just before the build starts.
- If another commit arrives after the build has already pulled its source, the current build is allowed to finish and the next Git poll queues the newer state for a follow-up build.
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

A new commit on the configured remote branch automatically triggers a fast-forward-only update, build and report to the currently selected ChatGPT conversation. `DEVBRIDGE: BUILD READY` (legacy `BUILD` accepted) remains available to force an immediate build of the current branch. `WAIT` pauses command-driven actions while Git monitoring remains active. `ABORT` stops immediately.

## Git safety
DevBridge never switches branches, refuses dirty working trees, uses git pull --ff-only, and never resets, rebases or force-pushes. Diverged/local-ahead histories stop safely.

## Configuration
See config/settings.json and config/projects.example.json. Actual projects config, browser profile, logs and state remain local and are ignored by Git. Optional versionSource supports incrementing a version from an HTTPS JSON manifest before build.

For the Android 5.1.1 branch `compat/android-5.1.1-api22-vosk`, DevBridge automatically invokes the same `scripts/build-publish-android511.ps1` script used by the VS Code task. It resolves the next `VersionCode` from the configured `versionSource` manifest and passes it as `-VersionCode`; no interactive prompt is required. Keep the Android 5.1.1 `versionSource` configured to the `android-5.1.1/version.json` file in the updates repository.

## Limitations
ChatGPT selectors and browser focus detection depend on the current UI/browser. Generation completion is inferred from a stable message snapshot. Handoff uses visible character count rather than tokens. Test the workflow before unattended use.
