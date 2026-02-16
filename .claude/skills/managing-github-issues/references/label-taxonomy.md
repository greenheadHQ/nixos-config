# Label Taxonomy 상세

`shren207/nixos-config` 레포지토리의 라벨 체계 정의.

## 설계 원칙

- 모든 이슈에 **1개 priority(필수) + area(해당 시) + 선택적 기본 라벨** 조합 부착
- area가 이슈 도메인과 맞지 않으면 생략 가능. 동일 도메인 이슈가 2개 이상 반복되면 새 area 추가 검토
- `area:` 접두사로 도메인 라벨을 GitHub 기본 라벨과 구분
- `priority:` 접두사로 우선순위를 명시적으로 표현

## Priority Labels

| Label | Hex Color | Description | 판단 기준 |
|-------|-----------|-------------|-----------|
| `priority:high` | `#b60205` (red) | 즉시 대응 필요 | 서비스 장애, 활성 보안 취약점, 데이터 손실 위험 |
| `priority:medium` | `#fbca04` (yellow) | 다음 작업 주기에 처리 | 회귀 위험 존재, 운영 효율 저하, 기술 부채 증가 중 |
| `priority:low` | `#0e8a16` (green) | 여유 있을 때 처리 | YAGNI 해당, 현재 동작에 문제 없음, 향후 확장 대비 |

## Domain Labels

| Label | Hex Color | Description | 해당 파일/모듈 예시 |
|-------|-----------|-------------|-------------------|
| `area:scalability` | `#c5def5` (light blue) | 호스트 확장성, 구조적 확장 | constants.nix, flake.nix, eval-tests.nix |
| `area:testing` | `#bfd4f2` (blue) | 테스트, CI/CD, 품질 보증 | tests/, lefthook.yml |
| `area:security` | `#d4c5f9` (purple) | 보안, 인증, 암호화, 시크릿 | secrets/, agenix, 방화벽 설정 |

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
5. SKILL.md의 Label Taxonomy 요약 라인에 새 라벨 이름 추가
6. CLAUDE.md의 스킬 라우팅 테이블에 해당 area가 반영되었는지 확인
