# Plan 014: Karakeep vhost의 CSP 전면 제거를 아카이브 렌더링 경로로 좁힌다

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report. When done, update the status row in `plans/README.md`.
>
> **Drift check (run first)**:
> `git diff --stat fb2a8aa6..HEAD -- modules/nixos/programs/caddy.nix`
> 변경이 있으면 "Current state"와 대조하고, 불일치 시 STOP.

## Status

- **Priority**: P3
- **Effort**: M
- **Risk**: MED (CSP를 잘못 좁히면 SingleFile 아카이브 렌더링이 다시 깨진다 —
  이것이 애초 제거 사유였다. 실 렌더링 검증은 운영자 `nrs` 후에만 가능)
- **Depends on**: none
- **Category**: security
- **Planned at**: commit `fb2a8aa6`, 2026-07-02
- **Issue**: https://github.com/greenheadHQ/nixos-config/issues/951

## Why this matters

Karakeep은 SingleFile로 아카이브한 **임의 웹페이지(제3자 제어 HTML/JS)**를
앱과 같은 origin에서 렌더링하는 서비스다. 그런데 Caddy vhost가 CSP 헤더를
**vhost 전체에서** 제거해, 악의적으로 조작된 페이지를 아카이브하는 것만으로
Karakeep origin에서 스크립트가 실행될 수 있는 저장형 XSS의 최종 방어선이
없다. 제거는 주석으로 문서화된 결정이고(아카이브 CSS 렌더링 차단 방지,
Tailscale 전용이라 위험 수용 — upstream karakeep#1977 참조), Tailscale 전용
바인딩도 사실이다. 이 plan은 그 결정을 뒤집는 게 아니라 **범위를 좁힌다**:
CSP 제거가 실제로 필요한 아카이브 자산 경로에만 적용하고 앱 셸 경로에는
표준 CSP를 복원한다. vhost에 이미 route 분기 구조(singlefile 경로)가 있어
구조적으로 저렴하다.

## Current state

- `modules/nixos/programs/caddy.nix:98-115` 부근 — Karakeep vhost:

```nix
virtualHosts."${subdomains.karakeep}.${base}" = {
  listenAddresses = [ minipcTailscaleIP ];
  extraConfig = ''
    ${securityHeaders}
    # CSP 헤더 제거: Karakeep iframe 내 SingleFile HTML의 CSS 렌더링 차단 방지
    # Tailscale VPN 전용이므로 XSS 위험 무시 가능
    # ref: https://github.com/karakeep-app/karakeep/issues/1977
    header -Content-Security-Policy
    header -Content-Security-Policy-Report-Only
    ${
      if singlefileBridgeCfg.enable then
        ''
          route {
            @singlefile path /api/v1/bookmarks/singlefile*
            handle @singlefile {
              reverse_proxy localhost:${toString singlefileBridgeCfg.port}
            }
            handle {
```

  (이하 기본 handle이 karakeep 포트로 reverse_proxy — 파일에서 직접 확인.)

- `securityHeaders`는 같은 파일 상단에 정의된 공통 헤더 블록 — CSP를 여기서
  포함하는지, 포함한다면 어떤 값인지 실행 시 확인 (제거 지시가 있다는 것은
  상류 또는 securityHeaders가 CSP를 설정한다는 뜻).
- upstream 맥락: karakeep#1977 — Karakeep이 응답에 싣는 CSP가 iframe 내
  SingleFile HTML의 스타일을 차단하는 문제. **어떤 경로의 응답이 문제였는지**
  (아카이브 자산 서빙 경로)를 이슈에서 확인하는 것이 Step 1이다.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Nix 평가 | `bash tests/run-eval-tests.sh` | 통과 |
| Flake | `nix flake check --no-build --all-systems` | exit 0 |
| 포맷 | `nixfmt --check modules/nixos/programs/caddy.nix` | exit 0 |
| upstream 이슈 확인 | WebFetch로 karakeep#1977 열람 | 문제 경로 식별 |

**운영자 후속 필수**: `nrs` 적용 후 ① 기존 아카이브 북마크의 SingleFile
렌더링(CSS 포함)이 정상인지 ② 앱 셸 응답에 CSP 헤더가 실리는지
(`curl -sI https://<karakeep 도메인>/ | grep -i content-security`) 확인.

## Scope

**In scope**:
- `modules/nixos/programs/caddy.nix`의 Karakeep vhost 블록만

**Out of scope** (do NOT touch):
- 다른 vhost들 (copyparty/immich 등)과 `securityHeaders` 공통 블록 자체.
- Karakeep 컨테이너 설정 (`karakeep.nix`).
- Tailscale 바인딩 (`listenAddresses`) — 결정된 구조.

## Git workflow

- Branch: `advisor/014-karakeep-csp-scoping`
- Commit 예: `fix(caddy): Karakeep CSP 제거를 아카이브 자산 경로로 한정`
- Push/PR은 운영자 지시가 있을 때만.

## Steps

### Step 1: CSP 제거가 필요한 최소 경로 식별

karakeep#1977과 Karakeep 문서에서 SingleFile 아카이브 HTML이 서빙되는 경로
패턴(예: assets 계열 경로)을 식별한다. 로컬에서 판단 근거가 부족하면
(경로 패턴을 공식 소스로 확정할 수 없으면) STOP.

**Verify**: 식별된 경로 패턴과 출처를 작업 노트에 기록.

### Step 2: vhost를 경로 분기 구조로 재작성

기존 route 분기(singlefile)를 활용해:

- 아카이브 자산 경로 matcher → `header -Content-Security-Policy` 유지
  (기존 주석도 이 블록으로 이동).
- 그 외(앱 셸) → CSP 제거 지시 없음 (상류/securityHeaders의 CSP가 그대로
  전달되게).

Caddy의 `header` 지시자 순서/상속 의미(route 내 header 처리)는 Caddy 문서
기준으로 확인하며 작성한다.

**Verify**: `nixfmt --check` + `bash tests/run-eval-tests.sh` +
`nix flake check --no-build --all-systems` → 전부 통과

### Step 3: 결정 기록 갱신

vhost 주석을 갱신한다: "CSP는 아카이브 자산 경로에서만 제거 (렌더링 호환) —
앱 셸은 표준 CSP 유지. 이전에는 vhost 전체 제거였음 (karakeep#1977)."

**Verify**: `grep -n "karakeep-app/karakeep/issues/1977" modules/nixos/programs/caddy.nix` → 여전히 1건 (출처 보존)

## Test plan

Nix 평가/flake check가 구문 게이트. 실 동작(렌더링 + 헤더)은 운영자 후속
절차로 명시 (Commands 표 참조) — eval로는 검증 불가능한 종류다.

## Done criteria

- [ ] Karakeep vhost에서 `header -Content-Security-Policy`가 경로 matcher
  블록 **안에만** 존재 (vhost 최상위에는 없음)
- [ ] `bash tests/run-eval-tests.sh` → exit 0
- [ ] `nix flake check --no-build --all-systems` → exit 0
- [ ] 최종 보고에 운영자 후속 확인 절차 2가지(렌더링/헤더) 명시
- [ ] `git diff --stat` → `modules/nixos/programs/caddy.nix` 1개 파일만
- [ ] `plans/README.md` 상태 행 갱신

## STOP conditions

- Step 1에서 아카이브 자산 서빙 경로를 공식 소스로 확정할 수 없다 — 추측으로
  matcher를 쓰면 렌더링이 다시 깨지거나 방어가 무의미해진다.
- Karakeep이 아카이브 HTML을 앱 셸과 **같은 경로/같은 문서 안에서** 서빙해
  경로 분기가 원리적으로 불가능하다 — 그 사실을 보고 (이 경우 원 결정(전면
  제거+위험 수용)이 옳았다는 결론이 되며, 그것도 유효한 산출물이다).
- upstream 이슈 열람이 불가능하다 (네트워크 도구 부재).

## Maintenance notes

- Karakeep 업데이트로 자산 서빙 경로가 바뀌면 matcher가 어긋나 렌더링 회귀가
  날 수 있다 — karakeep-update 후 렌더링 확인이 관례에 추가될 필요.
- 리뷰어는 앱 셸 경로에 실리는 CSP의 실제 값(상류가 보내는 것)이 앱 동작과
  호환되는지를 운영자 후속 확인 결과로 판단.
