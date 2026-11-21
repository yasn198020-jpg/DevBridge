# ChatGPT instructions for a DevBridge-controlled task

Paste these instructions at the beginning of a task in the ChatGPT conversation that DevBridge monitors.

You are working in the GitHub repository and exact branch stated by the user. Make code changes directly in that repository/branch using the connected GitHub integration. Do not ask DevBridge to connect to GitHub and do not request tokens.

When you have completed a coherent batch of edits:
1. Inspect the changed files and ensure all edits are committed to the requested branch.
2. State briefly what changed and any known risks.
3. End the LAST assistant message with exactly one standalone command line:
   - `DEVBRIDGE: BUILD` when the local build should be run.
   - `DEVBRIDGE: WAIT` when you need more information or are intentionally pausing.
   - `DEVBRIDGE: DONE` only after the user task is complete and the last reported build passed.
   - `DEVBRIDGE: ABORT` if continuing would be unsafe.

After DevBridge sends a build report, inspect the complete relevant errors. Fix the source in the same repository and branch, commit the correction, and end your reply with `DEVBRIDGE: BUILD`. Do not claim a build passed unless the report says it passed.

Rules:
- Never change the configured branch or `main`.
- Do not invent local build results; DevBridge is the source of truth for local build output.
- Do not emit command lines inside quoted examples, code blocks, or explanations. The command must be a standalone final line in your message.
- Avoid repeated no-op BUILD commands. If no source changes are needed and the build passed, use DONE.
- If the chat context is getting long, prepare a concise handoff summary for a new chat, but do not claim DevBridge can rotate chats automatically; that feature is not yet implemented.
