# LLM 이행 가이드 마크다운 템플릿

## 헤더 블록

blockquote 형태로 작업의 메타 정보를 한눈에 제공한다.

```markdown
> **대상**: <변경 대상 모듈/파일/서비스>
> **목표**: <이 가이드가 달성하는 최종 상태를 1문장으로>
> **예상 소요**: ~<N>분 (단일 세션 / 다중 세션)
> **난이도**: 단순 / 중간 / 복잡
> **관련 이슈**: #<N>
```

### 예시

```markdown
> **대상**: `modules/shared/programs/claude/files/skills/syncing-atuin/`
> **목표**: Atuin sync 스킬을 생성하여 shell history 동기화 절차를 자동화한다
> **예상 소요**: ~10분 (단일 세션)
> **난이도**: 단순
> **관련 이슈**: #252
```

## 핵심 원칙

작업 전체에 적용되는 불변 규칙을 1-3개로 기술한다.
LLM이 작업 중 판단이 필요할 때 참조하는 최상위 제약이다.

```markdown
## 핵심 원칙

1. **진실 원천 우선**: 이 가이드의 값보다 CLI/파일시스템에서 확인한 실제 값이 우선한다.
2. **기존 패턴 존중**: 코드베이스에 확립된 네이밍/구조 컨벤션을 따른다. 새 패턴을 도입하지 않는다.
3. **최소 변경 원칙**: 이슈에 명시된 범위만 변경한다. 인접 코드의 리팩토링은 하지 않는다.
```

## Phase 구조

### Phase 1: 사전 확인

CLI/파일시스템에서 현재 상태를 확인한다. 변경 전 기준선을 수립하는 Phase이다.

````markdown
## Phase 1: 사전 확인

다음 명령으로 현재 상태를 확인한다 (병렬 가능):

```bash
# 1. 현재 버전 확인
grep "version" modules/shared/programs/tool/default.nix

# 2. 관련 설정 확인
cat modules/shared/programs/tool/config.nix | head -20

# 3. 상수 참조 확인
grep "toolPath" libraries/constants.nix
```

**기대 결과**:
- version = "1.2.3" (이슈에 "1.2.3"이라 적혀 있지만, 실제 값이 다르면 실제 값 기준으로 진행)
- config.nix에 `enableFeature = false;` 존재
- constants.nix에 `toolPath = "/old/path";` 존재
````

**작성 규칙:**
- `(병렬 가능)` 힌트를 명시하여 LLM이 독립 명령을 동시 실행하도록 유도한다.
- 이슈에 기재된 값과 실제 값이 다를 수 있음을 명시한다 ("진실 원천 우선" 패턴).
- 기대 결과를 구체적으로 적어 LLM이 현재 상태와 비교할 수 있게 한다.

### Phase 2-N: 실행

BEFORE/AFTER 형식으로 변경 내용을 명시한다.

````markdown
## Phase 2: 실행

### 2-1. 버전 업데이트

**파일**: `modules/shared/programs/tool/default.nix`

BEFORE:
```nix
version = "1.2.3";
```

AFTER:
```nix
version = "1.3.0";
```

### 2-2. 설정 변경

**파일**: `modules/shared/programs/tool/config.nix`

BEFORE:
```nix
enableFeature = false;
```

AFTER:
```nix
enableFeature = true;
```
````

**작성 규칙:**
- BEFORE/AFTER 쌍을 반드시 제공한다. "version을 업데이트한다"같은 모호한 지시는 금지.
- 각 변경에 대상 파일 경로를 명시한다.
- 변경이 여러 파일에 걸치면 파일별로 소항목을 분리한다.

### 검증 + 커밋 Phase

변경 결과를 검증하고 커밋하는 최종 Phase이다.

````markdown
## Phase N: 검증 + 커밋

### 정적 검증

```bash
# 새 값 존재 확인 (병렬 가능)
grep -q 'version = "1.3.0"' modules/shared/programs/tool/default.nix
grep -q 'enableFeature = true' modules/shared/programs/tool/config.nix

# old 값 부재 확인 (병렬 가능)
! grep -q 'version = "1.2.3"' modules/shared/programs/tool/default.nix
! grep -q 'enableFeature = false' modules/shared/programs/tool/config.nix
```

### 빌드 검증

```bash
nrs
```

빌드가 성공하면 커밋한다.

### 커밋

```bash
git add modules/shared/programs/tool/default.nix modules/shared/programs/tool/config.nix
git commit -m "$(cat <<'EOF'
feat(tool): enable feature and bump to v1.3.0

- version: 1.2.3 → 1.3.0
- enableFeature: false → true

Closes #252
EOF
)"
```

### DA 피드백 (권장)

구현 완료 후, `/run-da for_pr` 스킬을 실행하여 코드 품질을 검증하고,
필요하면 `/parallel-audit`로 전수조사를 수행한 뒤 `/create-pr` 스킬로 PR을 생성한다.
````

## 커밋 메시지 템플릿

가이드에 포함하는 커밋 메시지는 완전한 형태로 사전 작성한다.

```text
git commit -m "$(cat <<'EOF'
<type>(<scope>): <요약>

<변경 내용 bullet points>

Closes #<이슈번호>
EOF
)"
```

- type: feat/fix/refactor/docs/chore 등 conventional commit 형식
- scope: 변경 대상 모듈명
- 요약: 50자 이내, 명령형 현재시제
- 변경 내용: BEFORE → AFTER 형태의 bullet points
- Closes: 관련 이슈 번호

## QA 감사 체크리스트 (스킬 관련 이슈용)

스킬 파일 변경 이슈의 경우, 가이드 마지막에 QA 체인을 포함한다.

```markdown
## QA 체크리스트

구현 완료 후 다음 순서로 검증한다:

1. **skill-reviewer**: 에이전트를 활용하여 SKILL.md의 품질 기준 준수 확인
   - frontmatter 유효성 (name, description, Triggers)
   - 본문 구조 (Purpose → 빠른참조 → 핵심절차 → 참조)
   - references/ 링크 유효성
2. **skill-creator**: 에이전트를 활용하여 evals/queries.json 검증
   - positive 10개 + negative 10개 충족
   - negative에 인접 스킬 트리거 포함
```

## 모범 패턴 (Issue #252 기반)

Issue #252의 LLM 이행 가이드에서 관찰된 효과적인 패턴:

### "진실 원천 우선" 패턴

```markdown
> 이슈에 "현재 버전 1.2.3"이라 기재되어 있으나, 실행 시점에서
> `grep version <파일>`로 실제 값을 먼저 확인한다.
> 실제 값이 다르면 실제 값을 BEFORE로 사용한다.
```

이슈 작성과 가이드 실행 사이의 시간차를 보상한다. 다른 PR이 먼저 머지되어 값이 변경되었을 수 있다.

### "병렬 힌트" 패턴

```markdown
다음 명령으로 현재 상태를 확인한다 (병렬 가능):
```

독립적인 명령들을 병렬 실행할 수 있음을 명시하여 LLM의 실행 효율을 높인다.

### "완전한 커밋 템플릿" 패턴

커밋 메시지를 LLM에게 자유작성시키지 않고, 가이드에 완성된 템플릿을 포함한다.
커밋 메시지의 type, scope, 본문 구조가 프로젝트 컨벤션과 일치하도록 보장한다.

### "조건부 분기" 패턴

```markdown
### 환경별 분기

- **macOS (Platform: darwin)**: 로컬에서 직접 실행
- **NixOS (Platform: linux)**: `ssh minipc`로 실행하되, 파일 편집은 로컬에서 수행
```

실행 환경에 따라 달라지는 행동을 명시하여 LLM이 올바른 경로를 선택하도록 한다.

### "미검증 주석" 패턴

```markdown
<!-- 미검증: NixOS에서 이 옵션이 적용되는지 확인 필요. macOS에서만 테스트됨. -->
```

가이드 작성 시점에 확인하지 못한 사항을 HTML 주석으로 표시한다.
실행 LLM이 해당 부분에서 추가 검증을 수행하도록 유도한다.
