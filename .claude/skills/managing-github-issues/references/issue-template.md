# Issue Template (고정)

이 템플릿은 모든 GitHub Issue에 **반드시** 사용해야 하는 고정 포맷이다.
포맷 일관성이 LLM 파싱, `gh issue view` 조회, 자동화의 핵심이므로 임의 변경을 금지한다.

## 템플릿

```markdown
## Summary

[1-2 문장으로 무엇을 왜 해야 하는지 요약]

## Context

[배경 설명]
- 현 상태는 어떤지
- 왜 이 변경이 필요한지
- 어떤 문제/한계가 있는지

## Affected Files

| File | Role | Required Change |
|------|------|-----------------|
| `path/to/file1` | 역할 | 변경 내용 |
| `path/to/file2` | 역할 | 변경 내용 |

## Proposed Changes

- [ ] 구체적 변경 사항 1
- [ ] 구체적 변경 사항 2
- [ ] 구체적 변경 사항 3

## Acceptance Criteria

- [ ] 완료 조건 1
- [ ] 완료 조건 2
- [ ] 완료 조건 3

## Notes

[제약사항, 관련 이슈 번호, 참고사항, 또는 "N/A"]
```

## 섹션별 작성 가이드

### Summary
- **길이**: 1-2 문장
- **포함**: what + why
- **예시**: "NixOS 호스트 2대 이상 추가 시 constants.nix의 IP/포트 구조와 eval-tests의 하드코딩된 호스트 참조를 리팩토링해야 한다. 현재는 1대 전용 설계라 확장 시 대규모 수정 필요."

### Context
- 현 상태 → 문제점 → 필요성 순으로 서술
- 관련 커밋이나 이전 결정이 있으면 참조
- LLM이 이 섹션만 읽고 작업 배경을 이해할 수 있어야 함

### Affected Files
- **반드시 테이블 형식** 사용 (LLM 파싱 용이)
- 파일 경로는 프로젝트 루트 기준 상대 경로
- 백틱(`` ` ``)으로 경로 감싸기
- Role: 이 파일이 프로젝트에서 하는 역할
- Required Change: 이 이슈를 해결하기 위해 이 파일에서 변경할 내용

### Proposed Changes
- **반드시 체크박스** (`- [ ]`) 사용
- 각 항목은 독립적으로 완료 가능한 단위
- 구현 순서대로 나열 (의존성 있으면 명시)
- 모호한 표현 금지 ("개선한다" → "X를 Y로 변경한다")

### Acceptance Criteria
- **반드시 체크박스** (`- [ ]`) 사용
- 검증 가능한 조건만 (주관적 판단 불가 항목 금지)
- 테스트 통과, 빌드 성공 등 객관적 기준
- 예시: "`nix eval --impure --file tests/eval-tests.nix` 통과"

### Notes
- 해당 없으면 "N/A" 기재 (섹션 자체를 삭제하지 않음)
- 관련 이슈는 `#번호` 형식으로 참조
- YAGNI 판단 근거, 선행 조건, 위험 요소 등 기재

## 작성 예시

```markdown
## Summary

Darwin(macOS) 설정에 대한 eval-test를 추가하여 macOS 설정 회귀를 pre-commit에서 자동 감지한다.
현재 eval-tests.nix는 NixOS config만 검증하며, Darwin은 `nix flake check`의 평가 가능 여부만 확인한다.

## Context

- 현재 `tests/eval-tests.nix`는 `flake.nixosConfigurations.greenhead-minipc.config`만 평가
- Darwin은 `lefthook.yml`의 pre-push `nix flake check --all-systems`에만 의존
- `nix flake check`는 "평가 가능한가"만 확인, "의도대로 설정되었는가"는 검증 불가
- Dock 설정, 키보드 단축키, Touch ID sudo 등 회귀 가치 있는 설정이 존재

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

## Acceptance Criteria

- [ ] `nix eval --impure --file tests/eval-tests.nix` 통과 (Darwin 테스트 포함)
- [ ] 기존 NixOS 29개 테스트 회귀 없음
- [ ] Darwin 설정을 의도적으로 변경하면 테스트 실패 확인

## Notes

- Darwin eval은 `--all-systems` 없이 x86_64-linux에서도 평가 가능한지 확인 필요
- 불가능하면 별도 `tests/darwin-eval-tests.nix` 파일로 분리 고려
```
