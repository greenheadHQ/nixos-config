# Plan 028: 원격 AI 세션의 macOS TCC 권한 정책을 DX 우선으로 확정하고 적용한다

> **Executor instructions**: 이 plan은 먼저 launcher별 TCC identity와 권한 지속성을
> 실측하고, 운영자에게 A/B/C 선택을 받은 뒤 선택한 정책만 구현한다. macOS Privacy &
> Security 설정 변경은 반드시 운영자가 직접 수행하거나 Computer Use의 action-time
> confirmation을 받은 뒤 수행한다. 선택 전에는 권한을 추가·삭제하거나
> `additionalDirectories`를 바꾸지 않는다. 완료 시 `plans/README.md`의 028 행을 갱신한다.
>
> **Drift check (run first)**:
> `git diff --stat 368e3140..HEAD -- modules/shared/programs/claude/files/settings.json modules/darwin/programs/claude-remote-control.nix modules/shared/programs/codex/files/config.darwin.toml scripts/ai/verify-ai-compat.sh .claude/skills/managing-claude-rc/SKILL.md`
> 위 파일이 바뀌었으면 Current state와 대조하고, TCC/remote-control 관련 의미 변경이면 STOP한다.

## Status

- **Priority**: P1
- **Effort**: M (실측·결정 S, 선택 정책 구현·재부팅 검증 S~M)
- **Risk**: MED (Option B는 권한 범위가 넓고, Option C는 보호 폴더 접근 DX가 낮아진다)
- **Depends on**: none
- **Category**: bug / dx / security
- **Planned at**: commit `368e3140`, 2026-07-13
- **Issue**: https://github.com/greenheadHQ/nixos-config/issues/1093

## Why this matters

휴대폰 원격 세션은 Mac 앞에서 TCC 팝업을 클릭할 수 없으므로, 로컬에서는 1회 승인으로
끝나는 요청이 원격에서는 세션 전체 hang이 된다. 2026-07-13 실측에서 Claude의 첫 Bash와
`SystemPolicyDesktopFolder` prompt가 같은 시각에 발생했고 20분 넘게 결과가 없었다.
최소권한만을 정답으로 고정하지 않고, **원격 작업 지속성(DX)을 최우선**으로 targeted
permission, Full Disk Access, on-demand access를 비교해 안정적인 운영안을 확정한다.

## Current state

- `modules/shared/programs/claude/files/settings.json:18-23`:
  ```json
  "additionalDirectories": [
    "~/Desktop",
    "~/Downloads",
    "~/Documents",
    "~/Workspace"
  ]
  ```
  보호 폴더 3개가 모든 Claude 세션에 영구 추가된다.
- `modules/darwin/programs/claude-remote-control.nix:30-42`는 launchd headless bridge를
  `bypassPermissions`로 실행한다. 이 프로세스는 Ghostty의 자식이 아니다.
- 실측 TCC attribution:
  - Claude Remote Control: responsible=Nix bash, accessing=`com.anthropic.claude-code`,
    service=`SystemPolicyDesktopFolder`.
  - Codex App remote: responsible=`com.openai.codex`, accessing=`find`,
    service=`SystemPolicyAppData`.
  - 직접 Ghostty 세션: responsible=Ghostty. 따라서 Ghostty 권한은 headless launcher에
    자동 승계되지 않는다.
- Apple은 stable code identity가 없으면 Files & Folders 결정이 버전 간 안정적으로
  재사용되지 않아 prompt가 반복될 수 있다고 설명한다.
- Claude는 영구 `additionalDirectories` 외에 세션 한정 `/add-dir`와 시작 시
  `--add-dir`를 공식 지원한다.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| 설정 문법 | `jq empty modules/shared/programs/claude/files/settings.json` | exit 0 |
| TCC 로그 | `/usr/bin/log show --style compact --info --debug --last 5m --predicate '(process == "sandboxd" OR process == "tccd")'` | launcher/service attribution 확인 |
| AI 호환 게이트 | `./scripts/ai/verify-ai-compat.sh` | FAIL 0 |
| 전체 게이트 | `bash tests/run-all-tests.sh` | FAILED 0 |
| 실배포 | `nrs` | activation 성공 |

## Suggested executor toolkit

- `finding-unknowns`: Option A/B의 stable identity를 구현 전에 실측한다.
- `managing-macos`: macOS Privacy & Security 운영 절차를 따른다.
- `managing-claude-rc`, `configuring-codex`: launcher별 runtime binding을 확인한다.
- `computer-use`: UI를 읽는 데 쓸 수 있으나, 권한 변경 클릭은 action-time confirmation이 필요하다.

## Scope

**In scope**:

- Option A: Claude/ChatGPT responsible app/binary의 필요한 Files & Folders/App Data 사전 허용
- Option B: Claude/ChatGPT responsible app/binary의 Full Disk Access 상시 허용
- Option C: `additionalDirectories`를 `~/Workspace`로 축소하고 `/add-dir` opt-in
- Ghostty 권한은 직접 터미널 세션 보조 선택지로만 평가
- 선택 정책의 문서·정적 검사·실배포 검증

**Out of scope**:

- TCC DB 직접 편집, `tccutil reset`을 이용한 무차별 초기화
- PPPC/MDM 신규 도입 (개인 Mac 한 대에 과도함; 실제 수요가 생기면 별도 이슈)
- 보호 폴더나 다른 앱 container를 광범위하게 스캔해 prompt를 억지 재현하는 것
- 1Password SSH/biometric 정책 — plan 029 소유

## Git workflow

- Branch: `fix/remote-tcc-dx-policy`
- Conventional commit 예: `fix(ai): 원격 세션 TCC 권한 정책 적용`
- 운영자 승인 전 commit/push/PR 금지. 실제 권한 클릭은 커밋 대상이 아니므로 PR 본문에 수동
  운영 단계와 실측 결과를 기록한다.

## Steps

### Step 1: launcher별 TCC baseline을 비자극 방식으로 기록한다

기존 로그와 현재 설정만 사용해 아래 표를 채운다. 새 prompt를 만들기 위해 보호 폴더를
스캔하지 않는다.

| Launcher | Responsible code | TCC service | Existing decision | Stable identity 후보 |
|----------|------------------|-------------|-------------------|-----------------------|
| Claude Remote Control | | | | |
| Codex App remote | | | | |
| Ghostty direct | | | | |

**Verify**: 표의 모든 행에 `log show` 근거 시각과 binary/bundle identifier가 있다.

### Step 2: Option A(targeted pre-authorization)를 먼저 실증한다

운영자 확인 후 System Settings > Privacy & Security에서 Step 1의 실제 responsible
주체에 필요한 Files & Folders/App Data 권한만 허용한다. Claude/Codex 프로세스를 재시작하고
Mac 재부팅 후 다음 두 케이스를 각각 실행한다.

1. repo 내부 read-only Bash — prompt 없이 성공해야 한다.
2. 운영자가 의도한 보호 폴더의 단일 임시 파일 read — prompt 없이 성공해야 한다.

테스트 후 로그에서 새 `AUTHREQ_PROMPTING`이 없는지 확인한다. versioned Nix bash 또는 Claude
binary 때문에 permission entry가 유지되지 않으면 결과를 `Option A unstable`로 기록한다.

**Verify**: 재부팅 후 두 launcher의 두 케이스가 성공하고 prompting 0건이면 A 통과.

### Step 3: A가 불안정하면 Option B(Full Disk Access)를 실제 후보로 실증한다

A가 실패한 경우에만 운영자에게 권한 확대 범위를 다시 보여주고 확인받는다. Claude/ChatGPT의
stable responsible app/binary에 Full Disk Access를 부여한 뒤 Step 2 matrix를 반복한다.
Ghostty FDA는 direct session만 대상으로 별도 행에 기록하며 remote 성공으로 간주하지 않는다.

**Verify**: 재부팅 후 Claude/Codex remote 둘 다 성공 + prompting 0건. 하나라도 실패하면 B 불합격.

### Step 4: 운영자 결정 게이트를 통과한다

아래를 한 표로 제시하고 A/B/C 중 하나를 운영자에게 선택받는다.

- A: targeted permission — DX 높음, 범위 중간, 지속성 실측 결과
- B: Full Disk Access — DX 최고, 범위 넓음, 지속성 실측 결과
- C: Workspace-only + `/add-dir` — DX 중간, 범위 최소, 항상 예측 가능

**Verify**: GitHub issue #1093 또는 세션에 운영자의 명시적 A/B/C 선택이 기록됨.

### Step 5: 선택 정책만 구현·문서화한다

- A/B: manual System Settings 절차, 실제 bundle/binary identity, 재부팅 검증, 업데이트 후
  재검증 조건을 `.claude/skills/managing-claude-rc/SKILL.md`에 기록한다. 선언적으로 확인
  불가능한 TCC state를 Nix 설정이 보장한다고 쓰지 않는다.
- C: `settings.json`에서 Desktop/Downloads/Documents를 제거하고 Workspace만 유지한다.
  `/add-dir`/`--add-dir` opt-in 절차를 문서화한다.
- 공통: 가능한 정적 불변식만 `verify-ai-compat.sh` 또는 적합한 테스트에 추가한다.

**Verify**: `jq empty`, `./scripts/ai/verify-ai-compat.sh`, `bash tests/run-all-tests.sh` 모두 성공.

### Step 6: nrs 후 원격 E2E를 수행한다

`nrs`를 실행해 설정/문서를 배포한다. Claude Remote Control과 Codex App에서 새 세션을 만들고
repo 내부 Bash와 의도된 보호 폴더 read를 각각 실행한다. 각 명령은 outer timeout을 두어 새
prompt가 생겨도 세션을 무한 대기시키지 않는다.

**Verify**: 두 launcher 모두 선택 정책의 기대 동작과 일치하고, 무한 대기 0건.

## Test plan

- 정적: JSON 문법, 선택 C이면 보호 폴더 문자열 부재, A/B이면 운영 문서에 exact identity와
  재검증 조건 존재.
- 통합: `verify-ai-compat.sh`, 전체 test suite.
- 런타임: launcher 2종 × repo/protected path 2종 × restart/reboot 2상태 matrix.
- 회귀: Ghostty direct 세션이 기존 파일 접근/터미널 기능을 유지함.

## Done criteria

- [ ] launcher별 TCC attribution 표 완성
- [ ] Option A 실측 완료, 불안정 시 Option B 실측 완료
- [ ] 운영자의 A/B/C 선택 기록
- [ ] 선택 정책만 구현·문서화
- [ ] `./scripts/ai/verify-ai-compat.sh` FAIL 0
- [ ] `bash tests/run-all-tests.sh` FAILED 0
- [ ] `nrs` 성공
- [ ] Claude/Codex remote E2E에서 무한 대기 0건
- [ ] `plans/README.md` 028 행 갱신

## STOP conditions

- TCC responsible identity가 재부팅 전후 달라짐 — A/B를 구현하지 말고 원인 보고.
- Option B가 Claude/Codex 중 한 launcher에만 적용됨 — Ghostty/ChatGPT 권한을 섞어 추정 금지.
- 운영자 A/B/C 선택이 없음 — 구현 시작 금지.
- TCC DB 직접 수정이나 SIP/보안 기능 비활성화가 필요해짐 — 범위 밖.
- 테스트가 다른 앱의 실제 private data를 읽어야만 통과함 — 임시 파일 fixture로 축소.

## Maintenance notes

- Claude/Codex 업데이트 후 responsible binary identity가 바뀌면 A/B permission을 재검증한다.
- A/B 채택 시 권한 범위는 PR 본문과 managing-claude-rc 문서 양쪽에 남긴다.
- C 채택 시 Desktop/Downloads/Documents 영구 추가 요청이 다시 나오면 #1093의 DX 결정부터
  재검토하고 기계적으로 되돌리지 않는다.
