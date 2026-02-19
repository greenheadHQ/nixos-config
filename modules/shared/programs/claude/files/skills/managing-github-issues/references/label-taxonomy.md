# Label Taxonomy 상세

GitHub 이슈의 라벨 체계 정의.

## 설계 원칙

- 모든 이슈에 **1개 priority(필수) + 1개 area(필수) + 선택적 기본 라벨** 조합 부착
- area 라벨 없는 이슈 등록은 금지. 기존 area가 맞지 않으면 새 area를 생성한 뒤 부착
- `area:` 접두사로 도메인 라벨을 GitHub 기본 라벨과 구분
- `priority:` 접두사로 우선순위를 명시적으로 표현

## Priority Labels

| Label | Hex Color | Description | 판단 기준 |
|-------|-----------|-------------|-----------|
| `priority:high` | `#b60205` (red) | 즉시 대응 필요 | 서비스 장애, 활성 보안 취약점, 데이터 손실 위험 |
| `priority:medium` | `#fbca04` (yellow) | 다음 작업 주기에 처리 | 회귀 위험 존재, 운영 효율 저하, 기술 부채 증가 중 |
| `priority:low` | `#0e8a16` (green) | 여유 있을 때 처리 | YAGNI 해당, 현재 동작에 문제 없음, 향후 확장 대비 |

## Area Labels

### 개념

- `area:` 접두사로 도메인 라벨을 GitHub 기본 라벨과 구분
- 모든 이슈에 **1개 area 필수** — area 없는 이슈 등록 금지
- 각 레포의 도메인에 맞는 area를 정의하여 사용

### 네이밍 규칙

- `area:` 접두사 필수
- 소문자, 하이픈 구분 (예: `area:frontend`, `area:ci-cd`, `area:auth`)
- 색상: 파스텔 계열 톤 통일 (#c5def5 ~ #f9d0c4 범위)

### 첫 사용 시 area 정의

새 레포에서 처음 이슈를 관리할 때:

1. `gh label list`로 기존 라벨 확인
2. `area:` 접두사 라벨이 없으면, 레포의 주요 도메인을 식별하여 2-5개 area 생성
3. 예시:
   - 웹앱: `area:frontend`, `area:backend`, `area:api`, `area:infra`
   - 인프라: `area:networking`, `area:security`, `area:monitoring`
   - 라이브러리: `area:core`, `area:docs`, `area:testing`

## 라벨 관리 명령어

### 라벨 추가

```bash
gh label create "area:newname" --description "설명" --color "hex6자리"
```

### 라벨 수정

```bash
gh label edit "area:oldname" --name "area:newname" --description "새 설명" --color "newhex"
```

### 라벨 삭제

```bash
gh label delete "area:oldname" --yes
```

### 현재 라벨 목록 확인

```bash
gh label list
```

## 라벨 추가 시 체크리스트

1. `area:` 또는 `priority:` 접두사 사용
2. 기존 라벨과 의미 중복 없는지 확인 (`gh label list`)
3. 색상은 같은 카테고리 내에서 톤 통일
4. description에 한국어로 용도 명시
