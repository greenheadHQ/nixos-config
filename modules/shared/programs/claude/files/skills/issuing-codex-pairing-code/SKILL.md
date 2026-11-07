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
   - If the helper reports that the local Codex app-server protocol does not expose `manualPairingCode`, state that no live code was issued because the helper failed before starting app-server. The pairing API is an experimental Codex surface (the helper checks `generate-ts --experimental` output and opts in via `capabilities.experimentalApi`), so this failure means the installed Codex build dropped or renamed the pairing API.
5. 정리는 사용자가 요청할 때만 수행한다. helper가 출력한 정확한 `Cleanup` 명령을 사용한다. 이 명령은 해당 발급의 비공개 runtime만 지정한다.
   - 연결 후에도 helper가 만든 app-server가 원격 제어를 담당한다. 별도 supervisor가 호출자 종료 후에도 이를 유지하며, `Cleanup` 명령은 그 인스턴스의 원격 연결도 종료한다.
   - 발급 완료 전 호출자가 끊기거나 시작·발급에 실패하면 supervisor가 직접 생성한 자식만 회수한다. 완료 인계 뒤에는 사용자의 명시적 정리 또는 app-server의 종료까지 유지한다.
   - 정리는 비공개 제어 소켓으로 supervisor에 요청한다. PID 파일·프로세스 이름 검색·기존 세션 탐색을 사용하지 않는다. runtime의 소유권·권한·표식이 바뀌면 정리를 거부하며, 추가 파일은 재귀 삭제하지 않고 남긴다.
   - runtime에는 helper의 비공개 복사본도 둔다. 원본 worktree가 정리되어도 출력된 `Cleanup` 명령은 이 복사본을 사용한다. 응답 유실은 정리 완료 여부를 확인하지 못한 상태이며, 원래 runtime 외의 세션을 찾아 종료하지 않는다.

```bash
# 실제 실행에는 helper가 출력한 Cleanup 명령을 그대로 사용한다.
python3 scripts/issue_pairing_code.py --cleanup <해당-비공개-runtime>
```

## Guardrails

- Live issuance is Darwin/macOS only.
- The helper must fail before binary lookup, socket discovery, supervisor spawn, or RPC on non-Darwin live runs.
- The helper must fail before socket discovery, supervisor spawn, or RPC when the local Codex app-server protocol does not expose a manual pairing-code response field.
- The helper uses only a helper-owned private runtime directory and detached supervisor. 서버 표준 출력·오류 및 원시 RPC를 파일에 기록하지 않는다.
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
