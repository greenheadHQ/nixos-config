# Issue Template

이슈 등록 시 사용하는 템플릿.
포맷 일관성이 LLM 파싱, `gh issue view` 조회, 자동화의 핵심이므로 구조를 유지한다.

## 템플릿

````markdown
## Summary (필수)

[1-2 문장으로 무엇을 왜 해야 하는지 요약. 체크리스트 A1: '무슨 문제 / 누가 / 현재 증상 / 기대 결과']

## Context (필수)

[배경 설명 — 체크리스트 A2]
- 현 상태는 어떤지
- 왜 이 변경이 필요한지 (안 하면 리스크)
- 어떤 문제/한계가 있는지

## References (필수)

[체크리스트 B1/B4. **실제 근거가 있으면 최소 1개 링크를 포함**한다. 근거가 전혀 없으면 섹션을 비우지 말고 `[UNVERIFIED]` 항목만으로 채운다.]

- [링크 텍스트](URL) — 한 문장으로 "무엇을 뒷받침하는지"
- `path/to/file.nix:LINE` 또는 `path/to/file.nix:START-END` — 코드 근거 (단일 라인 또는 라인 범위 허용)
- `#NNN` (이슈/PR 번호) 또는 머지된 commit SHA — **출처 입증에 불가결한 경우에만**. 단순 색인용 인용 금지 (close/rename 시 stale).

## PoC / Reproduction (선택)

[재현이 중요한 주장에 포함. 체크리스트 C1. 6필드 예시:]

```bash
# 환경: macOS 14.x, nrs 최신
# 입력: ...
# 절차:
<명령어>
# 기대 결과: ...
# 실제 결과: ...
# 성공 기준: ...
```

## Related Commits (선택)

- `<머지된 SHA>` — 커밋 메시지 한줄 요약
- `<머지된 SHA>` — 커밋 메시지 한줄 요약

## Affected Files (선택)

| File | Role | Required Change |
|------|------|-----------------|
| `path/to/file1` | 역할 | 변경 내용 |
| `path/to/file2` | 역할 | 변경 내용 |

## Proposed Changes (필수)

- [ ] 구체적 변경 사항 1 (필요 시 근거 링크 또는 `[UNVERIFIED]`)
- [ ] 구체적 변경 사항 2
- [ ] 구체적 변경 사항 3

## Notes (선택)

[제약사항, 관련 이슈 번호, YAGNI 판단 근거, `[UNVERIFIED]` 항목 목록]
````

## 섹션별 작성 가이드

### Summary (필수)
- 길이: 1-2 문장
- 포함: what + why
- 예시: "NixOS 호스트 2대 이상 추가 시 constants.nix의 IP/포트 구조와 eval-tests의 하드코딩된 호스트 참조를 리팩토링해야 한다. 현재는 1대 전용 설계라 확장 시 대규모 수정 필요."

### Context (필수)
- 현 상태 → 문제점 → 필요성 순으로 서술
- 관련 커밋이나 이전 결정이 있으면 참조
- LLM이 이 섹션만 읽고 작업 배경을 이해할 수 있어야 함

### References (필수)
- 비자명한 주장마다 근거 제공 (체크리스트 B1/B4)
- 근거 타입 (Source reliability 순위 — 체크리스트 B3): 공식 docs URL > repo 내부 파일(`path/to/file.nix:LINE` 또는 `path:START-END`) > 머지된 commit SHA > 관련 이슈/PR 번호 (`#NNN`) > blog > LLM 기억
- 관련 이슈/PR 번호 인용은 출처 입증에 불가결한 경우에만. 단순 색인용 인용은 close/rename 시 stale 위험.
- 근거 존재 시: 최소 1개 링크 또는 path 참조 필수
- 근거 부재 시: 섹션을 비우지 않고 `[UNVERIFIED]` 항목으로 대체
- 상충 시: `[CONFLICTING]` + 양측 인용 (체크리스트 E3)
- 라벨 체계 상세는 [체크리스트 라벨 체계](../../write-handoff/references/llm-friendly-checklist.md#라벨-체계-anti-hallucination) 참조 (`[UNVERIFIED]`/`[INFERRED]`/`[CONFLICTING]` 정의)

### PoC / Reproduction (선택)
- 재현이 중요한 버그 리포트나 검증 필요한 주장에 포함
- 6필드 모두 채움: 환경 / 입력 / 절차 / 기대 결과 / 실제 결과 / 성공 기준 (체크리스트 C1)
- 절차는 코드블록 + 언어 태그 (`bash`, `nix` 등) 사용

### Related Commits (선택)
- 포맷: `- \`머지된 SHA\` — 커밋 메시지 한줄 요약` (안정 식별자만; mid-flight partial hash 박제 금지 — squash 후 dangling 위험)
- 이 이슈가 생성된 배경/맥락이 되는 기존 머지된 커밋만 기재 (단순 색인용 인용 금지)
- 포함 기준은 SKILL.md Step 2 참조

### Affected Files (선택)
- 반드시 테이블 형식 사용 (LLM 파싱 용이)
- 파일 경로는 프로젝트 루트 기준 상대 경로
- 백틱(`` ` ``)으로 경로 감싸기
- 포함 기준은 SKILL.md Step 2 참조

### Proposed Changes (필수)
- 반드시 체크박스 (`- [ ]`) 사용
- 각 항목은 독립적으로 완료 가능한 단위
- 구현 순서대로 나열 (의존성 있으면 명시)
- 모호한 표현 금지 ("개선한다" → "X를 Y로 변경한다")

### Notes (선택)
- 추가 참고사항이 있는 경우에만 포함
- 관련 이슈는 `#번호` 형식으로 참조
- YAGNI 판단 근거, 선행 조건, 위험 요소 등 기재

## 작성 예시

> 가상 예시 주의: 아래는 템플릿 작성 형식 예시이며, 실제 repo 상태와 시점에 따라 불일치할 수 있다 (예: `darwinConfigurations` 평가는 이미 `tests/eval-tests.nix`에 존재). line 번호는 작성 시점 기준으로 실측 반영한다.

```markdown
## Summary

Darwin(macOS) 설정에 대한 eval-test를 추가하여 macOS 설정 회귀를 pre-commit에서 자동 감지한다.
현재 eval-tests.nix는 NixOS config만 검증하며, Darwin은 `nix flake check`의 평가 가능 여부만 확인한다.

## Context

- 현재 `tests/eval-tests.nix`는 `flake.nixosConfigurations.greenhead-minipc.config`만 평가
- Darwin은 `lefthook.yml`의 pre-push `nix flake check --all-systems`에만 의존
- `nix flake check`는 "평가 가능한가"만 확인, "의도대로 설정되었는가"는 검증 불가
- Dock 설정, 키보드 단축키, Touch ID sudo 등 회귀 가치 있는 설정이 존재

## References

- [nix flake check docs](https://nixos.org/manual/nix/stable/command-ref/new-cli/nix3-flake-check.html) — "평가 가능성"만 확인함을 뒷받침
- `tests/eval-tests.nix:15-17` — NixOS config 평가 블록 (`nixosCfg = flake.nixosConfigurations.greenhead-minipc.config`)
- `lefthook.yml`의 `pre-push.flake-check` 항목 — `nix flake check --all-systems` 훅 근거 (라인번호 박제 회피: hook 추가/이동 시 라인이 밀린다)
- `[UNVERIFIED]` Darwin eval이 x86_64-linux에서 평가 가능한지는 실측 필요 (Notes 참조)

## Related Commits

- `<머지된 SHA>` — feat(tests): pre-commit E2E eval 테스트 도입 — 네트워크 노출 경계 보안 검증
- `<머지된 SHA>` — fix(tests): 검토 피드백 루프 완료 — 테스트 정리 + 등급 달성

## Affected Files

| File | Role | Required Change |
|------|------|-----------------|
| `tests/eval-tests.nix` | Pre-commit 보안 E2E 테스트 | Darwin config 평가 테스트 추가 |
| `modules/darwin/configuration.nix` | macOS 시스템 설정 | (읽기 전용 — 검증 대상) |
| `lefthook.yml` | Git 훅 설정 | 변경 불필요 (기존 eval-tests 커맨드 재사용) |

## Proposed Changes

- [ ] `tests/eval-tests.nix`에 `darwinCfg` 변수 추가 (`flake.darwinConfigurations.greenhead-MacBookPro.config`)
- [ ] Touch ID sudo 활성화 검증 테스트 추가
- [ ] Dock autohide, tilesize 검증 테스트 추가
- [ ] 키보드 반복 속도 설정 검증 테스트 추가

## Notes

- `[UNVERIFIED]` Darwin eval은 `--all-systems` 없이 x86_64-linux에서도 평가 가능한지 실측 필요
- 불가능하면 별도 `tests/darwin-eval-tests.nix` 파일로 분리 고려
```
