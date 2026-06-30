---
name: issuing-codex-pairing-code
description: Issue a Codex remote-control computer pairing/authentication code only when the latest user message explicitly asks to issue or share a Codex pairing code, computer connection code, authentication code, or remote-control code. Do not use for general remote-control diagnostics, setup explanation, connection troubleshooting, or UI navigation unless code issuance is explicitly requested.
---

# Issue Codex Pairing Code

Use this skill to issue a Codex remote-control computer pairing code through a helper-owned temporary app-server. The skill does not pair the device itself.

## Procedure

1. Confirm the latest user message explicitly asks for a pairing/authentication/computer connection code.
   - If the user only asks for diagnostics, setup help, or UI navigation, do not run the script. Ask a short clarification instead.
2. Confirm the host is macOS/Darwin for live issuance.
   - On Linux/NixOS, do not attempt live issuance. Use `--mock` only for fixture validation and state that NixOS live issuance was not run.
3. Run the helper from this skill directory:

```bash
python3 scripts/issue_pairing_code.py --user-requested-code
```

4. Share only the `Code`, `Expires`, and `Cleanup` lines with the user.
   - Do not store raw pairing codes, raw pairing tokens, full JSON-RPC payloads, or full helper output in committed files, progress notes, PR text, or issue comments.
5. Leave cleanup under user control unless they ask you to clean up. Use the exact `Cleanup` line printed by the helper; it includes the unique tmux session and private runtime directory for that issuance.

```bash
tmux kill-session -t codex-pair-bg-...; rm -rf /private/tmp/codex-pairing-code-...
```

## Guardrails

- Live issuance is Darwin/macOS only.
- The helper must fail before binary lookup, socket discovery, tmux spawn, or RPC on non-Darwin live runs.
- The helper uses only a helper-owned private runtime directory and tmux session by default.
- Do not automatically discover or reuse ambient Codex app-server sockets.
- Do not use Computer Use, browser UI automation, SSH, launchd/systemd installation, persistent daemon setup, or scheduler cleanup for this flow.
- Codex has no perfect structural auto-trigger block, so the description and this explicit consent gate are both part of the safety boundary.

## Validation

Use mock mode for deterministic checks:

```bash
python3 scripts/issue_pairing_code.py --mock --json
```

Run tests from the repo root:

```bash
python3 -m unittest discover modules/shared/programs/claude/files/skills/issuing-codex-pairing-code/tests
```
