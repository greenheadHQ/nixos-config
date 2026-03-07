# CIR/ADR 템플릿

## 소규모: 인라인 한줄 CIR

대안 1개 거부, 단일 trade-off인 경우.

```
# CIR: <선택한 방식> 선택 — <거부한 대안>은 <거부 이유>
```

예시:
```python
# CIR: string split 선택 — regex는 이 단순 패턴에서 과도함
parts = line.split(":")
```

```nix
# CIR: mkOutOfStoreSymlink 사용 — 순수 Nix 복사는 양방향 수정 불가
".claude/settings.json".source = config.lib.file.mkOutOfStoreSymlink path;
```

## 중규모: 인라인 블록 CIR

대안 2개 이상 거부, 또는 방향 전환 1회인 경우.
의사결정이 발생한 코드 위치에 블록 주석으로 기록한다.

```
# === Change Intent Record ===
# v1 (<ref>): <첫 번째 접근과 결과>
# v2 (<ref>): <두 번째 접근과 결과>
# v3 (이번 변경): <최종 결정과 이유>
#    trade-off: <감수하는 단점>
```

`<ref>` 자리에는 가용한 참조를 우선순위 순으로 사용한다:
- PR 번호: `v1 (PR #115)` — squash merge 후에도 유효한 영속적 참조
- 커밋 해시: `v1 (b9cd235)` — PR 머지 전 또는 non-squash 워크플로우
- PR+해시 병기: `v1 (b9cd235, PR #115)` — 둘 다 있으면 가장 풍부한 참조
- 참조 없음: `v1:` — 로컬 미커밋 작업이면 생략 가능

### Canonical Example (PR #121)

pre-flight 소스 빌드 체크의 allowlist → blocklist 전환에서 실제 사용된 CIR:

```bash
# known-heavy: 소스 빌드 시 장시간 소요되는 패키지 (Rust 컴파일 등)
# 각 항목은 패키지명 접두사. 매칭: ^<name>-[0-9]+\.[0-9]+ (semver 시작 필수)
#
# === Change Intent Record ===
# v1 (b9cd235): known-heavy blocklist 구상 → 관리 부담 우려로 known-trivial allowlist 채택
# v2 (f09a575): activation-script 등 false positive 발생, trivial 패턴 추가로 대응
# v3 (이번 변경): allowlist 방식이 두더지 잡기(끝없는 패턴 추가)임을 확인,
#    원래 구상대로 known-heavy blocklist로 회귀. 미등록 패키지는 무시(수동 관리).
#    trade-off: 새 무거운 패키지 추가 시 수동 등록 필요하나,
#              false positive를 크게 줄여 사용자 경험이 압도적으로 나음.
local heavy_packages=(
    anki    # 로컬 overlay (doInstallCheck=false) → Hydra 캐시 없음, 항상 소스 빌드
    mise    # Rust 패키지 → flake update 후 캐시 미스 시 장시간 빌드
)
```

이 예시의 핵심 구조:
- **버전별 이력**: v1 → v2 → v3로 의사결정 흐름을 시간순 기록
- **참조 포함**: 각 버전에 커밋 해시 명시. squash merge 환경이라면 `v1 (b9cd235, PR #115)` 또는 `v1 (PR #115)`처럼 PR 번호를 병기/대체하면 머지 후에도 추적 가능
- **전환 이유**: 각 단계에서 왜 방향을 바꿨는지 명시
- **trade-off 명시**: 최종 결정의 단점을 솔직하게 기록

## 커밋 메시지 CIR 섹션

중/대규모 변경에서 커밋 메시지 본문에 추가하는 섹션.
커밋 제목(첫 줄) 아래, 본문에 `## Change Intent Record` 헤더로 시작한다.

```
<type>(<scope>): <변경 요약>

<변경 설명 (선택)>

## Change Intent Record
- v1 (<ref>): <접근 방식과 결과>
- v2 (<ref>): <다음 접근과 결과>
- v3 (이번): <최종 결정과 이유>

trade-off: <감수하는 단점 요약>
```

`<ref>`는 인라인 블록 CIR과 동일한 우선순위: PR 번호 > 커밋 해시 > 생략.

### Canonical Example (PR #121 커밋 메시지)

```
refactor(rebuild): pre-flight 체크를 known-trivial allowlist에서 known-heavy blocklist로 전환

known-trivial allowlist 방식은 새 trivial derivation(rebuild-common.sh,
activation-script.drv 등)이 나올 때마다 패턴 추가가 필요한 두더지 잡기였음.

## Change Intent Record
- v1 (b9cd235): 처음에 known-heavy blocklist 구상 → 관리 부담 우려로 allowlist 채택
- v2 (f09a575): activation-script false positive → 패턴 추가로 대응
- v3 (이번): allowlist의 근본적 한계 확인, 원래 구상대로 blocklist로 회귀

trade-off: 새 무거운 패키지 추가 시 수동 등록 필요하지만,
false positive 제로로 사용자 경험이 압도적으로 나음.
```

## PR 본문 CIR 섹션

대규모 변경(방향 전환 2회 이상, 아키텍처 결정)에서 PR 본문에 추가.
`## Summary` 바로 아래에 `## Change Intent Record` 섹션을 배치한다.

```markdown
## Summary
- <변경 요약 bullet points>

## Change Intent Record
- v1 (<ref>): <접근 → 결과>
- v2 (<ref>): <접근 → 결과>
- v3 (이번): <최종 결정>

trade-off: <단점>이지만, <장점>이 압도적으로 나음.

## Test plan
- [ ] <검증 항목>
```

## 작성 가이드

### 버전 표기

- `v1`, `v2`, `v3` 순서로 시간순 기록
- 참조 우선순위 (가용한 것 중 상위 사용):
  1. PR 번호: `v1 (PR #115)` — squash merge 후에도 영속적
  2. 커밋 해시: `v1 (b9cd235)` — PR 전이거나 non-squash 환경
  3. 병기: `v1 (b9cd235, PR #115)` — 둘 다 있으면 가장 풍부
  4. 생략: `v1:` — 로컬 미커밋 작업
- 현재 변경은 `(이번)` 또는 `(이번 변경)`으로 표기

### trade-off 기록

trade-off는 최종 결정의 단점을 솔직하게 기록하되, 왜 그 단점을 감수하는지 이유도 함께 적는다:
```
trade-off: <단점>이지만, <이유/장점>
```

### 언어별 주석 문법

| 언어 | 주석 문법 |
|------|----------|
| Shell/Python/Nix | `# === Change Intent Record ===` |
| JavaScript/TypeScript | `// === Change Intent Record ===` |
| CSS | `/* === Change Intent Record === */` |
| HTML | `<!-- === Change Intent Record === -->` |
| SQL | `-- === Change Intent Record ===` |
| Lua | `-- === Change Intent Record ===` |

블록 CIR의 각 줄도 해당 언어의 한줄 주석 문법을 따른다.

## 조회 결과 표시 템플릿

CIR/ADR 조회 결과를 사용자에게 보여줄 때 아래 2단계 포맷을 사용한다.

### Stage 1: Summary 테이블 (항상 표시)

```markdown
### CIR 조회 결과: <검색 대상>

| # | 위치 | 규모 | 핵심 결정 | 참조 |
|---|------|------|----------|------|
| 1 | `<파일:라인>` | 소/중/대 | <한줄 요약> | PR #N / `hash` |
| 2 | `<커밋 메시지>` | 중 | <한줄 요약> | `hash` |
```

### Stage 2: Detail 타임라인 (사용자 요청 시 또는 1건일 때 자동 표시)

```markdown
#### CIR #1: <제목>
- **위치**: `<파일:라인>` 또는 커밋 `<hash>`
- **타임라인**:
  - v1 (<ref>): <접근 → 결과>
  - v2 (<ref>): <접근 → 결과>
  - v3 (최종): <결정>
- **trade-off**: <감수하는 단점>
- **참조**: PR #N, 커밋 `hash`
```

### 표시 규칙

- 검색 결과가 3건 이상이면 Summary만 먼저 보여주고, 사용자가 번호를 지정하면 Detail을 표시한다.
- 검색 결과가 1~2건이면 Summary + Detail을 함께 표시한다.
- 검색 결과가 없으면 Fallback 검색을 수행한다. Fallback에서도 없으면 "해당 범위에서 CIR/ADR 기록 및 관련 의사결정 흔적을 찾지 못했습니다." 와 함께 검색 범위를 넓힐 것을 제안한다.
- Fallback 검색으로 발굴한 결과는 Summary 테이블의 규모 열에 `(추정)` 을 붙여 정형 CIR과 구분한다.

## Git Trailer 포맷

중/대규모 CIR에서 커밋 메시지 끝에 추가하는 기계 검색용 trailer.

```
CIR: <식별자>
```

- 식별자는 `<scope>-<주제>` 형태로 짧게 작성한다 (예: `rebuild-preflight-blocklist`)
- 커밋 메시지 본문과 trailer 사이에 빈 줄이 있어야 git이 trailer로 인식한다
- 검색: `git log --format="%(trailers:key=CIR)"`
- squash merge 시 자동 보존이 보장되지 않으므로 보조 수단으로만 사용한다

### CIR이 불필요한 경우

다음 상황에서는 CIR을 생략한다:
- 단순 버그 수정 (원인이 명확하고 대안이 없는 경우)
- 타이포/포맷 수정
- 의존성 버전 업데이트 (특별한 이유가 없는 경우)
- 한 가지 방법밖에 없는 변경
