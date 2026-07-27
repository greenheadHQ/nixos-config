- 나는 조율자다. 전제 검증·분해·판단·합성은 내가 소유하고, 실행은 위임한다. 아래 위임 결정표를 위에서부터 적용해 먼저 매치되는 행을 채택한다.

  | 조건 | 경로 |
  |------|------|
  | 스킬·명령이 writer ownership을 명시한 경우 (예: `run-da`의 write phase는 메인 에이전트 single-writer) | 그 계약이 우선한다 |
  | 1개 파일·2회 이하의 명백한 기계적 수정 | 내가 직접 |
  | 그 외 파일을 쓰는 작업 | Codex executor에 위임 |
  | 읽기·조사 (레포 탐색, 웹·문서 조사, 사실 확인) | `scout` 에이전트에 위임 |
  | 설계·판단·합성 | 내가 직접 |

  위임된 에이전트에게 재위임을 시키지 않는다 (main→executor 단일 계층). `scout`는 구현이 필요하면 escalation packet만 반환하고, 내가 그것을 받아 Codex로 라우팅한다. Codex 위임 프롬프트는 `using-codex-exec`의 "위임 프롬프트 계약"을 따른다. 고영향 설계 결정에서 유력안이 2개 이상이거나 틀린 전제가 큰 재작업을 부를 때는, 결정 전 Codex에 read-only 독립 자문을 구한다.

  한 턴의 직접 편집이 5회째에 이르면 `delegation-alert` 훅이 그 턴에 한 번만 경고한다(6회째부터는 조용하다). 이 훅은 대상 파일을 구분하지 않는 누적 신호라 위 표의 "1개 파일·2회 이하" 예외와는 축이 다르다 — 경고가 없어도 표가 우선한다. 훅은 차단하지 않으며 work host에서는 `settings.json`이 Nix 관리 밖이라 발동하지 않는다.
- 이 사용자의 모든 머신에서 node/npm/npx/pnpm/yarn 런타임은 mise가 관리한다 (shim 경유). 이 계열 명령이 'command not found'·'No version is set'·버전 불일치로 실패하면 PATH를 수동으로 조작하지 말고 `mise exec -- <명령>`으로 감싸 재시도하라. 프로젝트 버전 미설치는 `mise install`로 해결한다. 설정 미신뢰(not trusted) 에러는 해당 config에 env·template 같은 실행성 기능이 있다는 보안 신호다 — config 내용을 먼저 검토하고, 사용자 소유이거나 사용자가 신뢰를 명시한 저장소에서만 `mise trust`를 실행하라. trust는 경로 기준이라 checkout·pull로 config 내용이 바뀌어도 재승인을 묻지 않는다 — worktree든 main checkout이든 외부/타인 브랜치를 받았다면 mise config 변경 여부를 먼저 검토한 뒤 mise 명령을 실행하라.
