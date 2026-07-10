---
name: using-toss-api
description: |
  토스증권 OpenAPI 사용(시세/계좌/주문).
  Trigger: '토스증권', 'toss api', '주식 시세', '주문 실행', 'toss CLI'.
  NOT for: 일반 투자 분석(별도 스킬 소관), 시크릿 관리 일반(managing-secrets).
---

# 토스증권 OpenAPI 사용

## 개요 + SoT 규칙

이 스킬은 토스증권 OpenAPI를 대화형 에이전트와 로컬 `toss` CLI에서 안전하게 쓰기 위한 운영 가이드다. 시세·종목, 계좌·자산, 주문, 조건주문 API를 다룬다.

이 문서의 API 사실 서술은 orientation이다. endpoint, header 필요 여부, request/response schema, rate limit group의 진실 원천은 아래 두 파일이다.

- `.claude/skills/using-toss-api/references/vendor/openapi.json`
- `modules/shared/scripts/toss/endpoints.json`

문서 요약과 SoT가 충돌하면 SoT를 우선하고, `docs-refresh` 후에는 이 문서의 stale 여부를 같이 점검한다.

## 인증 흐름

- Base API server: `https://openapi.tossinvest.com`
- 인증 방식: OAuth 2.0 Client Credentials Grant
- 토큰 엔드포인트: `POST /oauth2/token`
- 토큰 만료: `expires_in=86400`초, 즉 24시간
- refresh token은 없다. 만료 또는 강제 갱신 시 같은 token endpoint로 재발급한다.
- client당 유효 access token은 1개다. Mac과 miniPC가 같은 client를 쓰면 한쪽에서 재발급한 순간 다른 쪽 토큰은 즉시 무효화된다.
- CLI는 401 또는 `invalid_token`을 받으면 캐시를 폐기하고 1회만 강제 재발급 후 재시도한다.

토큰과 client secret은 출력, 로그, 영속 파일, 부모 셸 export에 남기지 않는다. 시크릿 배선 자체는 `managing-secrets` 범위다.

## X-Tossinvest-Account 규칙

`GET /api/v1/accounts`는 Bearer token만 필요하다. 계좌 선택 전 계좌 목록을 조회해야 하므로 `X-Tossinvest-Account` 헤더를 붙이지 않는다.

사용자 컨텍스트 API만 `X-Tossinvest-Account: {accountSeq}` 헤더가 필수다. 판별 기준은 `modules/shared/scripts/toss/endpoints.json`의 `requiresAccount` 필드다. 이 필드는 OpenAPI operation parameter가 `#/components/parameters/AccountSeq`를 참조하거나 inline `X-Tossinvest-Account` header parameter를 가진 경우 true다.

## Rate Limit

SoT는 OpenAPI operation description의 Rate Limits Group과 실제 응답의 `X-RateLimit-Limit` 헤더다. 429 응답에서는 `Retry-After`를 우선한다. `toss api`는 응답의 `X-RateLimit-*`/`Retry-After` 헤더를 stderr에 `toss-rate-limit:` prefix로 출력하고, 주문 계열 호출이면 원장 레코드의 `response.rateLimitHeaders`에도 남긴다.

대표값은 overview 문서 기준으로만 참고한다.

| Group | 대표값 |
|-------|--------|
| `AUTH` | 5/s |
| `MARKET_DATA` | 10/s |
| `ORDER` | 6/s, 개장 피크 09:00-09:10 KST에는 3/s |

`MARKET_DATA_CHART`, `STOCK`, `MARKET_INFO`, `RANKING`, `MARKET_INDICATOR`, `ACCOUNT`, `ASSET`, `ORDER_HISTORY`, `CONDITIONAL_ORDER` 등 그 외 그룹의 운영 한도는 미확정으로 취급하고 응답 헤더로 확인한다.

## 함정 4종

1. Mac에서 Tailscale Mullvad exit node가 ON이면 출발지가 일본 IP로 바뀌어 IP whitelist에서 차단된다.
2. IP whitelist는 토스 콘솔에서 관리한다. 등록된 회선 공인 IP만 허용되며, 같은 회선(NAT) 뒤의 Mac과 miniPC는 하나로 커버된다. 현재 출발지 IP는 `toss doctor`로 확인해 콘솔 등록값과 비교한다 (실제 IP는 저장소에 두지 않는다).
3. sandbox 또는 모의투자는 없다. 주문 API는 실계좌 주문이므로 `--dry-run`을 먼저 사용한다.
4. Mac과 miniPC가 같은 client를 쓰면 토큰 재발급이 서로의 토큰을 즉시 무효화한다. 401 자동 회복에 의존하되, 반복 401이면 다른 호스트의 갱신 여부를 의심한다.

## toss CLI 사용법

CLI는 구현되어 운영 기준으로 사용한다. 실제 API 호출을 수반하는 항목은 네트워크 가능한 환경에서 스모크 테스트 후 결과를 확정한다. 단, 스모크 테스트는 read-only endpoint 또는 `--dry-run`으로만 수행한다 — 주문 계열 mutation은 실계좌 주문이므로(함정 3: sandbox 없음) 사용자의 별도 명시 승인 없이 실행하지 않는다.

운영 가능 host는 현재 Mac뿐이다 (SA token으로 credential을 `op read`). MiniPC는 `programs/toss` 모듈이 준비되어 있으나 #1044(전용 vault/SA 분리) 전까지 `homeserver.toss.enable = false`라 opnix credential이 materialize되지 않으므로, MiniPC에서 `toss token`·`toss api`는 credential 부재로 실패한다. MiniPC에서는 이 절차를 실행하지 않는다.

### `toss token [--force]`

access token을 발급하고 휘발성 runtime 경로에 0600으로 캐시한다. 만료 60분 전이면 재발급한다. `--force`는 캐시를 무시하고 재발급한다.

### `toss accounts`

`GET /api/v1/accounts`를 호출해 계좌 목록을 조회한다. 이 호출은 Bearer token만 사용하며 `X-Tossinvest-Account`를 붙이지 않는다. 응답의 첫 번째 `accountSeq`를 기본 계좌번호 캐시에 저장한다.

### `toss api <METHOD> <PATH> [--account ACCOUNT_SEQ] [--data JSON] [--dry-run] [--no-notify]`

범용 REST 래퍼다. CLI 코드에 path별 header 규칙을 하드코딩하지 않고 `endpoints.json` metadata를 읽는다.

- method+exact path 우선으로 metadata를 찾고, 실패하면 template path matcher를 사용한다.
- `requiresAccount=true`이면 `--account` 또는 캐시된 기본 계좌가 필요하다.
- metadata를 찾지 못한 unknown endpoint는 fail-closed로 취급한다. 계좌를 결정할 수 없으면 호출하지 않는다.
- `--dry-run`은 metadata/account 판정과 주문 원장 dry-run 기록만 수행하고, 토큰 발급·네트워크 전송·토큰 캐시 쓰기를 하지 않는다. sandbox가 없으므로 주문 전 기본 경로다.
- 주문 mutation 또는 unknown endpoint는 주문 보상 통제 대상이다. redacted 주문 원장은 `~/.local/state/toss/orders.jsonl`에 0700/0600 권한으로 best-effort append한다.
- 주문 성공 시 Pushover 알림은 기본 ON이다. 명령 단위 억제는 `--no-notify`, 환경 단위 억제는 `TOSS_NOTIFY=0`을 사용한다.

### `toss doctor`

side-effect 없는 오프라인 진단 명령이다. Tailscale exit node 상태, 출발지 공인 IP(콘솔 whitelist와 육안 비교), credential 파일·`op` 실행 파일의 존재(presence), token 캐시의 로컬 만료 여부(locally-unexpired)를 점검한다. `op` 실제 접근 권한이나 서버측 token 유효성은 검사하지 않으므로, SA가 revoke되었거나 다른 호스트의 재발급으로 캐시 token이 무효화된 상태도 `present`/`locally-unexpired`로 표시된다. 실제 검증은 `toss token --force` 또는 첫 API 호출로 확인한다. VPN을 자동 해제하지는 않는다.

## 유지보수 레시피: docs-refresh

공식 문서가 바뀌면 네트워크 가능한 환경에서 references 4종을 다시 받은 뒤 metadata를 재생성하고 diff를 리뷰한다.

```bash
curl -fsSL https://openapi.tossinvest.com/openapi-docs/latest/openapi.json \
  -o .claude/skills/using-toss-api/references/vendor/openapi.json
curl -fsSL https://openapi.tossinvest.com/openapi-docs/overview.md \
  -o .claude/skills/using-toss-api/references/vendor/overview.md
curl -fsSL https://openapi.tossinvest.com/openapi-docs/latest/api-reference/README.md \
  -o .claude/skills/using-toss-api/references/vendor/api-reference.md
curl -fsSL https://openapi.tossinvest.com/llms.txt \
  -o .claude/skills/using-toss-api/references/vendor/llms.txt

scripts/toss/generate-endpoint-metadata.sh
git diff -- .claude/skills/using-toss-api/references/vendor modules/shared/scripts/toss/endpoints.json
```

리뷰 체크리스트:

- endpoint 추가/삭제와 `operationId` 변경
- `requiresAccount`, `rateLimitGroup`, `isKnownOrderMutation` 변화
- template path의 `pathRegex`, `pathParamNames` 변화
- 이 `SKILL.md`의 요약이 stale해졌는지 여부

## 엔드포인트 탐색 jq 레시피

특정 endpoint metadata 확인:

```bash
jq '.endpoints[] | select(.method == "POST" and .path == "/api/v1/orders")' \
  modules/shared/scripts/toss/endpoints.json
```

특정 경로의 request schema 확인:

```bash
jq '.paths["/api/v1/orders"].post.requestBody.content["application/json"].schema' \
  .claude/skills/using-toss-api/references/vendor/openapi.json
```

계좌 헤더가 필요한 endpoint와 rate limit group 분포 확인:

```bash
jq -r '.endpoints[] | select(.requiresAccount) | "\(.method) \(.path)"' \
  modules/shared/scripts/toss/endpoints.json

jq -r '.endpoints[].rateLimitGroup // "null"' \
  modules/shared/scripts/toss/endpoints.json | sort | uniq -c
```
