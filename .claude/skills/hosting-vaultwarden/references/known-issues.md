# Vaultwarden Known Issues

## ADMIN_TOKEN 평문 경고

- 관리자 패널에 "plain text ADMIN_TOKEN is insecure" 경고 표시
- Argon2id 해싱으로 전환 가능하나, 초기 복잡도를 고려하여 v1에서는 평문 사용
- Tailscale 전용 + root 권한 필수 환경에서 실질적 위험 낮음
- 향후 개선: 컨테이너 내부에서 `vaultwarden hash` -> agenix secret 교체

## 환경변수 파일 주입 방식 (caddy-env 패턴)

- Vaultwarden은 `_FILE` 접미사 환경변수 미지원
- `vaultwarden-env` oneshot 서비스가 agenix secret -> tmpfs 환경변수 파일 생성
- `environmentFiles`로 컨테이너에 주입, `ConditionPathExists`로 안전장치
- 패턴 동일: `caddy-env` (Cloudflare token), `copyparty-config` (비밀번호)

## SIGNUPS_ALLOWED=false에서 계정 생성

- 로그인 페이지에 "Create Account" 버튼 미표시 (정상)
- 관리자 패널(`/admin`) -> Users -> Invite로 이메일 초대
- 초대 후 `/#/register`에 직접 접속하여 계정 생성 (초대된 이메일만 허용)

## WebSocket 실시간 동기화

- Vaultwarden v1.29+에서 WebSocket이 동일 HTTP 포트로 통합
- Caddy `reverse_proxy`가 WebSocket 업그레이드를 자동 처리
- 별도 설정 불필요 (별도 WebSocket 포트/경로 프록시 불필요)

## 헬스체크 시작 시 일시 실패 (exit code 4)

- `nrs` 적용 시 컨테이너 재시작 직후 헬스체크 transient 서비스가 start-period(30초) 내에 실행되면 exit code 4 발생 가능
- `nrs`가 exit code 4를 경고로 처리하므로 빌드 결과물 정리 등 후속 작업은 정상 진행
- 30초 후 자동으로 `healthy` 상태로 전환
- 확인: `sudo podman inspect vaultwarden | jq '.[0].State.Health.Status'`

## 이미지 버전 고정 + 업데이트 자동화

- `vaultwarden/server:1.35.2` (`:latest` 미사용)
- 재부팅 시 예기치 않은 버전 변경 방지
- `homeserver.vaultwardenUpdate.enable = true`로 매일 06:30 자동 버전 체크 + Pushover 알림
- 수동 업데이트: `sudo vaultwarden-update` (pinned tag pull -> digest 비교 -> 재시작 -> 헬스체크)
- 통합 업데이트 시스템 상세: `running-containers` 스킬의 [../running-containers/references/service-update-system.md](../../running-containers/references/service-update-system.md) 참조

## Master Password 복구 불가

- Bitwarden은 클라이언트 측 암호화 (서버에 키 저장 안 함)
- Master Password를 잊으면 서버 관리자도 vault 복구 불가능
- 비상 대책: Master Password를 안전한 물리적 장소에 별도 보관
