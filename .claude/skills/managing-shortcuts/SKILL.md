---
name: managing-shortcuts
description: |
  This skill should be used when the user asks about iOS Shortcuts management,
  Cherri DSL compilation, prompt-render presets, or the mobile prompt workflow.
  Triggers: "iOS Shortcuts", "Cherri", "cherri DSL", "prompt-render", "prompt preset",
  "프리셋", "프롬프트 렌더", "cheat-browse --prompts", "Shortcut 빌드", "Shortcut 서명",
  "모바일 프롬프트", "shortcuts sign", "shortcut import".
---

# iOS Shortcuts 관리 (Cherri DSL + prompt-render)

Cherri DSL 기반 iOS/macOS Shortcuts 빌드 파이프라인과 prompt-render 프리셋 시스템을 다룹니다.

## 목적과 범위

- Cherri DSL로 iOS Shortcuts를 선언적으로 빌드/서명/배포
- prompt-render CLI로 LLM 프롬프트 프리셋 렌더링 및 클립보드 복사
- iPhone에서 Tailscale VPN + SSH로 프리셋 원탭 실행

## 모듈 구조

### Shortcuts 빌드 파이프라인

| 파일 | 역할 |
|------|------|
| `modules/darwin/programs/shortcuts/default.nix` | Cherri DSL 빌드 파이프라인 (상수 주입 + 서명 + import) |
| `modules/darwin/programs/shortcuts/sources/prompt-render.cherri` | Prompt Render Shortcut 소스 (SSH로 MiniPC CLI 호출) |

### prompt-render CLI

| 파일 | 역할 |
|------|------|
| `scripts/prompt-render.sh` | preset 템플릿 추출 + placeholder 치환 + clipboard 복사 |
| `scripts/prompts/README.md` | 프롬프트 시스템 설명서 |
| `scripts/prompts/modules/` | 재사용 프롬프트 모듈 (principles, planning, verification 등) |
| `scripts/prompts/presets/` | 실전 프리셋 (bugfix, feature-dev-full, code-review 등) |

### CLI 래퍼 및 통합

| 파일 | 역할 |
|------|------|
| `modules/shared/programs/cheat/default.nix` | `prompt-render` + `cheat-browse` CLI 래퍼 배포 |
| `modules/shared/programs/cheat/files/scripts/cheat-browse.sh` | fzf 브라우저 (`--prompts` 모드로 preset 선택 + 렌더) |

## 빌드 파이프라인

```
.cherri 소스
  -> substituteInPlace (constants.nix 상수 4개 주입: SSH_HOST, SSH_USER, SSH_PORT, SSH_PATH_EXPORT)
  -> cherri --skip-sign (unsigned .shortcut, Nix sandbox에서 Apple ID 접근 불가)
  -> shortcuts sign --mode anyone (signed, macOS 14.4+ 유일 작동 모드)
  -> open (import 다이얼로그 1클릭)
```

- personal Mac에서만 활성화 (`hostType == "personal"`)
- `home.activation.importShortcuts`로 멱등 설치 (이미 존재하면 skip)
- `--derive-uuids` 사용 금지 (GroupingIdentifier 충돌로 if/else 블록 구분 불가, PR #133)

## prompt-render CLI

### 사용법

```bash
# 대화형 렌더링
prompt-render --preset feature-dev-full

# --var로 변수 지정
prompt-render --preset feature-dev-full --var DA_TOOL="codex exec"

# non-interactive + JSON 모드 (모바일/자동화용)
prompt-render --preset bugfix --non-interactive --format json --stdout-only

# preset 목록 조회
prompt-render --list-presets --format json

# fzf 브라우저로 preset 선택 + 렌더
cheat-browse --prompts
```

### Exit codes (text 모드)

| 코드 | 의미 |
|------|------|
| 0 | 성공 |
| 1 | usage 오류 |
| 2 | 누락 변수 |
| 3 | preset 미발견 |

### JSON 모드 계약

- 항상 exit 0, 성공/실패는 `ok` 필드로 판단
- stdout에 순수 JSON만 출력
- `missing` 필드: 누락 변수 메타데이터 배열 (name, desc, context, options, default)

### 프리셋 구조

프리셋 파일 (`scripts/prompts/presets/*.md`):
- ` ```text ``` ` 블록: 렌더링 대상 템플릿
- ` ```vars ``` ` 블록: 변수 메타데이터 (`NAME|desc|options|default`)
- `{PLACEHOLDER}`: 대문자 치환 변수

### 변수 스키마

| 변수 | 용도 |
|------|------|
| `{DA_MODEL_1}`, `{DA_MODEL_2}` | DA 모델 |
| `{DA_TOOL}` | DA 도구 |
| `{DA_INTENSITY}`, `{DA_TIMING}` | DA 제어 |
| `{LEARN_TARGET}`, `{FAMILIAR_TECH}`, `{TARGET}` | 도메인 변수 |

## iOS Shortcut 워크플로우 (Prompt Render)

iPhone에서 Tailscale VPN + iOS Shortcuts의 `Run Script over SSH`로 preset을 원탭 복사:

1. Phase 1: `--list-presets --format json`으로 preset 목록 조회
2. Phase 2: `chooseFromList`로 preset 선택
3. Phase 3: 변수 없이 렌더링 시도 → 성공 시 클립보드 복사
4. Phase 4: 변수 누락 시 `missing` 메타데이터로 동적 UI 생성 (options → chooseFromList, 없으면 텍스트 입력)
5. Phase 5: 변수 포함 최종 렌더링 → 클립보드 복사

Cherri DSL 주의사항:
- `count()`는 action 타입 반환 → 숫자 비교 불가, 문자열 변환 후 비교
- `chooseFromList` trailing newline 이슈 → `replaceText`로 제거
- single quote 이스케이프: `replaceText("'", "'\\''", ...)`

## 새 Shortcut 추가 절차

1. `modules/darwin/programs/shortcuts/sources/`에 `.cherri` 소스 추가
2. `default.nix`에 derivation + activation 추가
3. 상수 플레이스홀더(`@SSH_*@`)는 `substituteInPlace`로 주입
4. `nrs` 실행 → 서명 + import 다이얼로그 1클릭

## 새 preset 추가 절차

1. `scripts/prompts/presets/`에 `.md` 파일 추가
2. ` ```text ``` ` 블록에 템플릿 작성, `{PLACEHOLDER}` 사용
3. 필요 시 ` ```vars ``` ` 블록에 메타데이터 추가
4. `prompt-render --preset <name>` 으로 테스트

## 자주 발생하는 문제

1. **Shortcut 서명 실패**: Apple ID 미로그인 시 발생 → Apple ID 로그인 후 재시도
2. **cherri --derive-uuids 문제**: if/else/endif 블록 구분 불가 → 사용 금지 (PR #133)
3. **iOS Shortcut preset not found**: trailing newline 이슈 → `replaceText("\n", "", ...)` 필수
4. **prompt-render jq not found**: JSON 모드에서 jq 미설치 시 graceful 에러 반환
5. **shortcuts sign stderr 경고**: `ERROR: Unrecognized attribute string flag '?'`는 무해 (이슈 #131)

## 레퍼런스

- Cherri DSL: `inputs.cherri` (flake input)
- 프롬프트 시스템 상세: `scripts/prompts/README.md`
- 모바일 워크플로우 상세: `docs/PROMPT_MOBILE_SHORTCUT.md`
- Folder Actions (FFmpeg 등 폴더 감시)는 `managing-macos` 스킬 참조
