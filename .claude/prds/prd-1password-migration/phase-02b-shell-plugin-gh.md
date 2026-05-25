# Phase 2b: Shell Plugin gh

Parent PRD: [PRD: Bitwarden(Vaultwarden) → 1Password 마이그레이션 + LLM 주도 개발 생태계](../prd-1password-migration.md)
Status: Done (PR 대기)
Last Updated: 2026-05-25

## Objective

`gh` CLI를 1Password Shell Plugin alias로 자동 인증 흐름에 편입하여, `~/.config/gh/hosts.yml` 평문 oauth_token 의존을 제거하고 LLM 자동화 스크립트가 `gh pr create` 호출 시 1Password vault에서 PAT를 투명하게 주입받게 한다. 다른 도구(aws/npm/anthropic 등)는 yagni — 확장 트리거를 박제만.

## Context From Master PRD

- Goals covered: G-2 (op CLI 통합)
- Success Criteria: SC-2 (Shell Plugin alias 동작)
- Requirements covered: FR-11, NG-4
- Key scenarios touched: Scenario 2 (Mac gh pr create)

## Phase Discovery Gate

- [ ] 관련 코드/파일: `modules/shared/programs/git/default.nix` (programs.gh enable), `modules/shared/programs/shell/default.nix` (zsh init/aliases), `modules/darwin/home.nix`
- [ ] 관련 테스트/fixture: 없음
- [ ] 관련 docs/spec/외부 참조: https://developer.1password.com/docs/cli/shell-plugins/, https://developer.1password.com/docs/cli/shell-plugins/nix/, https://developer.1password.com/docs/cli/shell-plugins/github/
- [ ] 관련 command 또는 도구: `op plugin init gh`, `nrs darwin`, `gh pr list`
- [ ] Phase 1의 gh PAT가 1Password Automation vault `github-pat` item에 저장 완료
- [ ] 발견 사항이 후속 phase를 바꾸면 PRD 먼저 갱신

## Scope

### In Scope

- `op plugin init gh` 1회 실행: 1Password가 `github-pat` item과 `gh` command를 binding하는 `~/.config/op/plugins.sh` 생성
- `~/.config/op/plugins.sh`의 sourcing을 Home Manager `programs.zsh.initContent`에 declarative 등록 — 단순 source 라인이 아니라 file 존재 여부 guard 포함
- `~/.config/gh/hosts.yml`에서 평문 oauth_token 제거 + 구 PAT GitHub 측 revoke + audit (Phase 1에서 deferred한 gh PAT rotation 후반 3단계)
- 확장 트리거 정량 기준 박제 (managing-secrets SKILL.md에 1줄): "추가 shell plugin 도입 조건 = (a) 해당 도구 secret을 .env로 export하는 패턴 ≥ 2건 발생 OR (b) agenix 평문 노출 위험 보고 1건"
- 기존 `programs.gh = { enable = true; }` (modules/shared/programs/git/default.nix:176)는 그대로 유지 — Plugin이 alias로 wrapping

### Out of Scope

- aws/npm/anthropic 등 다른 shell plugin 도입 (확장 트리거 발생 시 별 epic)
- MiniPC `gh` 인증 전환 (Phase 3 — opnix가 SA token으로 PAT 주입)

## Implementation Checklist

- [ ] Phase 1의 gh PAT (`github-pat` item in Automation vault) 존재 확인: `op_get github-pat token`
- [ ] `op plugin init gh` 실행 (Mac 사용자 shell에서 직접 1회):
  - 1Password가 어떤 item을 binding할지 물음 → Automation vault의 `github-pat` 선택
  - default 인증 모드 선택 (보통 "Use my default account")
  - `~/.config/op/plugins.sh` 생성됨 확인
- [ ] `~/.config/op/plugins.sh` 내용 검토: `alias gh="op plugin run -- gh"` 라인 존재
- [ ] Home Manager 모듈 수정 (`modules/shared/programs/shell/default.nix` 또는 적합한 모듈):
  ```nix
  programs.zsh.initContent = lib.mkAfter ''
    # 1Password Shell Plugins (op plugin init gh)
    if [ -f "$HOME/.config/op/plugins.sh" ]; then
      source "$HOME/.config/op/plugins.sh"
    fi
  '';
  ```
  - guard 포함 (file 부재 시 silent skip)
- [ ] `nrs darwin`
- [ ] 새 zsh 세션에서 검증:
  - [ ] `type gh` → `gh is an alias for op plugin run -- gh` 출력
  - [ ] `gh api user` → biometric prompt 1회 → login=`greenheadHQ` 응답
  - [ ] 30분 내 두 번째 `gh pr list` → biometric 없이 통과
- [ ] `~/.config/gh/hosts.yml` 백업 후 `oauth_token` 라인 제거 (`yq` 또는 수동 편집). 이후 `cat ~/.config/gh/hosts.yml` 출력에 평문 token 부재 검증
- [ ] GitHub Settings → Developer settings → Personal access tokens에서 **구 PAT revoke** (Phase 1에서 신규 발급 후 미revoke 상태). 이름·생성일자로 식별
- [ ] `git log -p --all -- '**/hosts.yml' '**/*.env' 2>/dev/null | rg 'gho_[A-Za-z0-9]+'` 0건 확인 (과거 commit leak 검증). 발견 시 GitHub Secret scanning 알림 확인 + BFG repo-cleaner 검토(별 task)
- [ ] 확장 트리거 박제: Phase 5에서 `managing-secrets/SKILL.md`에 명문화할 텍스트를 본 phase의 Discoveries / Decisions에 미리 메모

## Validation Strategy

- `gh api user` 응답으로 plugin alias가 정상 wrapping됐는지 확인. 30분 캐시 동작 검증으로 사용 가능성 확인. hosts.yml 평문 token 부재 재확인.

## Validation Checklist

- [ ] Static check 통과: `nix flake check --no-build --all-systems`
- [ ] 자동 test — N/A
- [ ] API/CLI 검증: `type gh` + `gh api user` + `gh pr list`
- [ ] Browser/UI E2E — N/A
- [ ] Agent/dev browser check — N/A
- [ ] Mobile/app simulator — N/A
- [ ] Visual/screenshot check — N/A
- [ ] Observability/logging — 1Password 데스크탑 Activity log에서 op plugin run 호출 기록 확인
- [ ] Manual smoke check — Claude Code session에서 `gh pr list` 호출 시 biometric prompt 1회 → 정상
- [ ] 해당 시 error/empty/loading/permission/retry/rollback — 1Password 데스크탑 quit 후 `gh api user` 실패 메시지 적절성 확인

## Exit Criteria

- [ ] Phase objective 달성 (`gh` alias가 1Password Shell Plugin 경유)
- [ ] FR-11 구현 + FR-3 Phase 2b 부분(hosts.yml 평문 제거 + 구 PAT revoke + audit) 구현
- [ ] `~/.config/gh/hosts.yml`에 평문 oauth_token 부재 (검증 명령: `grep -i oauth_token ~/.config/gh/hosts.yml` 0건)
- [ ] 구 gh PAT가 GitHub 측에서 revoked 상태 (사용자 manual 확인)
- [ ] `git log -p` 평문 leak 검색 0건 또는 발견 후 후속 대응 결정됨
- [ ] 확장 트리거 텍스트가 Phase 5 작업 항목으로 reserved
- [ ] 다음 phase (Phase 3 MiniPC) 시작 blocker 없음

## Phase-End Multi-Pass Review

- [ ] 1. Intent/coverage — SC-2 부분 달성 (Mac만, MiniPC는 Phase 3)
- [ ] 2. Correctness — 첫 호출 biometric, 캐시 hit, 1Password quit 시나리오 처리
- [ ] 3. Simplicity — initContent에 source guard 1줄 + plugins.sh 1회 init만
- [ ] 4. Code quality — Home Manager 표준 patterns (lib.mkAfter, file guard) 사용
- [ ] 5. Duplication/cleanup — 기존 `programs.gh` 충돌 없음 확인 (Plugin은 alias 수준이라 programs.gh는 그대로)
- [ ] 6. Security/privacy — hosts.yml 평문 token 완전 제거 재확인
- [ ] 7. Performance — Plugin alias가 op CLI fork overhead 추가 — 30분 캐시로 사용성 보존
- [ ] 8. Validation — `gh api user` + `type gh` + manual smoke로 충분
- [ ] 9. Future-phase — Phase 3 MiniPC도 동일 plugin alias 패턴 사용 가능성 (단 SA token 모드로 호출). Phase 5에 확장 트리거 박제 작업 reserved
- [ ] 10. PRD sync — master PRD Status, Current Phase, Change Log 갱신

## Discoveries / Decisions

- 확장 트리거 텍스트 (Phase 5에 박제 예정): "추가 shell plugin 도입 조건 = (a) 해당 도구 secret을 .env로 export하는 패턴 ≥ 2건 발생 OR (b) agenix 평문 노출 위험 보고 1건"
- **op plugin 인증 모드**: `op plugin init gh`에서 github-pat(Automation) credential + "Use as global default on my system" 채택 — gh는 디렉토리 무관 범용 도구이고 LLM 자동화 cwd가 다양하므로 directory-scoped보다 global이 적합.
- **plugins.sh declarative sourcing**: op이 안내하는 `echo "source ..." >> ~/.zshrc`는 회피 — `~/.zshrc`가 Home Manager nix store 심링크(read-only)라 직접 append 시 깨진다. `programs.zsh.initContent`에 file-guard source chunk로 declarative 등록 (`shell/default.nix`).
- **hosts.yml 제거 후 keyring fallback**: hosts.yml 평문 oauth_token 제거 시 gh가 keyring의 구 `gho_` OAuth로 fallback한다. 단 op plugin alias가 `GH_TOKEN`(github-pat)을 우선 주입하므로 실 인증은 github-pat이고, keyring `gho_`는 unused fallback(OS 암호화, 평문 아님)이라 사용자 결정으로 유지.
- **구 PAT 부재**: 기존 gh 인증은 OAuth(`gho_`)였고 Phase 1의 `ghp_`가 첫 PAT라 GitHub 측에 revoke할 구 PAT가 없음 (사용자 확인). FR-3 "구 PAT revoke"는 대상 없음으로 충족.

## Phase Change Log

- 2026-05-17: Phase file created.
- 2026-05-25: Phase 2b 구현 완료 (PR 대기). `shell/default.nix` initContent에 plugins.sh file-guard source chunk 추가 + `op plugin init gh`(global default, github-pat) + nrs 적용. 검증: `type gh`=alias(op plugin run -- gh), `gh api user`=greenheadHQ(op plugin 경유 github-pat 주입). hosts.yml 평문 oauth_token 0건(yq 제거+백업). git history leak 0건. 구 PAT 없음 확인, keyring `gho_` unused fallback 유지 결정. 확장 트리거는 Phase 5 reserved.
