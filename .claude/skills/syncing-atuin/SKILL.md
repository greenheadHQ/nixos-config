---
name: syncing-atuin
description: |
  Sync Atuin shell history, 암호화 키 복구, atuin-clean-kr.
  Trigger: 'atuin 동기화 오류', 'encryption key', 'atuin-clean-kr', '한글 히스토리 삭제', 'atuin 설정'.
  NOT for tmux (use managing-tmux). NOT for SSH (use managing-ssh).
---

# Atuin 히스토리 동기화

Atuin 쉘 히스토리 동기화 가이드입니다.

## 목적과 범위

Atuin 동기화 상태 점검, 한글 히스토리 정리, encryption key 문제 분리를 다룬다.

## Known Issues

**Atuin v1 API deprecated**
- `atuin status` 명령어가 4XX 에러 반환 가능
- v2 API 사용 중, `last_sync_time` 파일이 CLI sync에서 자동 업데이트되지 않음
- 동기화 자체는 정상 작동

**`atuin history delete` 서브커맨드 미존재 (v18.13.3)**
- `atuin history` 하위에 `delete` 명령어가 없음
- 한글 포함 항목 일괄 삭제: `atuin-clean-kr` 스크립트 사용
- DB 경로: `~/.local/share/atuin/history.db`

**DB migration 불일치 (nixpkgs 버전 다운그레이드 시)**
- 새 버전의 atuin이 DB에 migration을 적용한 후, 구버전으로 돌아가면 발생
- 에러: `migration XXXXXXXX was previously applied but is missing in the resolved migrations`
- 원인: atuin DB migration은 forward-only — 한번 적용되면 해당 버전 이상을 유지해야 함
- 해결: nixpkgs를 해당 migration을 포함하는 버전 이상으로 업데이트 (`nix flake update nixpkgs`)
- 사례: v18.13.0의 `20260224000100` ("history author intent") migration이 Mac DB에만 적용된 상태에서 nixpkgs lock이 v18.12.1을 가리켜 발생 (PR #333)
- 예방: `nix run nixpkgs#atuin` 등으로 nixpkgs lock보다 새 버전을 임시 실행하지 않기

## 빠른 참조

### 히스토리 정리

```bash
# 한글 포함 항목 미리보기
atuin-clean-kr --dry-run

# 한글 포함 항목 일괄 삭제 (백업 후 삭제)
atuin-clean-kr
```

### 상태 확인

```bash
# 동기화 상태 (4XX 에러 발생 가능)
atuin status

# 마지막 동기화 시간 확인
cat ~/.local/share/atuin/last_sync_time

# 수동 동기화
atuin sync
```

### 주요 파일 위치

| 파일 | 용도 |
|------|------|
| `~/.config/atuin/config.toml` | Atuin 설정 |
| `~/.local/share/atuin/` | 데이터 디렉토리 |
| `~/.local/share/atuin/last_sync_time` | 마지막 동기화 타임스탬프 |

## 핵심 절차

1. `atuin status`/`atuin sync`로 동기화 자체를 확인한다.
2. `last_sync_time`과 DB 상태를 확인해 표시 이슈와 실제 동기화 이슈를 분리한다.
3. 한글 히스토리 렌더링 문제는 `atuin-clean-kr`로 정리한다.
4. 계정 이동 시 encryption key 불일치를 복구가 아닌 재초기화 대상으로 처리한다 (재초기화 시 로컬 히스토리 삭제, 마이그레이션 불가).

## 자주 발생하는 문제

1. **atuin status 4XX**: v1 API deprecated, 동기화는 정상
2. **encryption key 불일치**: 계정별 고유 키, 마이그레이션 불가
3. **zsh 한글 레이아웃 깨짐**: zsh-autosuggestion + 한글 경로 조합 문제 (근본 원인: zsh-autosuggestion)
4. **한글 포함 히스토리 TUI 렌더링 깨짐**: zsh-autosuggestion이 한글 포함 명령어를 제안할 때 발생, SQLite 직접 삭제로 해결
5. **DB migration 불일치**: nixpkgs보다 새 버전의 atuin을 임시 실행하면 DB migration이 적용되어, 이후 구버전에서 에러 발생. nixpkgs 업데이트로 해결

## 레퍼런스

- 트러블슈팅: [references/troubleshooting.md](references/troubleshooting.md)
