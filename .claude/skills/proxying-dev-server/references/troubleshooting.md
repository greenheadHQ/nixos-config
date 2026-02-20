# Dev Proxy 상세 운영/트러블슈팅

## 모듈 구조

| 파일 | 역할 |
|------|------|
| `modules/nixos/programs/dev-proxy/default.nix` | dev-proxy CLI + activation + Caddy vhost |
| `modules/nixos/options/homeserver.nix` | `devProxy` 옵션 정의 |
| `modules/nixos/programs/caddy.nix` | reverse proxy 통합 |
| `modules/nixos/lib/caddy-security-headers.nix` | Caddy 공통 보안 헤더 |
| `libraries/constants.nix` | `domain.subdomains.dev = "dev"` |

## 작동 원리

1. `dev-proxy PORT` 실행
2. `/run/caddy/dev-upstream`에 `reverse_proxy localhost:PORT` 기록
3. `systemctl reload caddy`로 설정 재해석
4. `dev.greenhead.dev` 요청이 upstream으로 전달

비활성 상태는 기본 503 응답(`No dev server running`)을 사용한다.

## 안전장치

- 원자적 쓰기(`mktemp` + `mv`)로 부분 쓰기 방지
- 포트 숫자/범위 검증으로 설정 인젝션 방지
- reload 실패 시 이전 상태 복원
- `off --hard`에서 시스템 포트 kill 거부
- 부팅 시 oneshot으로 upstream 파일 초기화
- `homeserver.reverseProxy.enable` 의존 assertion

## 운영 팁

```bash
# 리스닝 포트 확인
ss -Htn state listening

# 로그 확인
sudo journalctl -u caddy -n 20

# 프록시 해제 + 프로세스 종료
dev-proxy off --hard
```

## 자주 발생하는 문제

### 1) HMR 불능 (Vite)

- 원인: `server.hmr.clientPort` 미설정
- 조치: `clientPort: 443`, `host: 'dev.greenhead.dev'` 명시

### 2) 503 지속

- 원인: upstream 미설정 또는 앱 미기동
- 조치: `dev-proxy status`, `ss -tlnp | grep <PORT>` 확인

### 3) Caddy reload 실패

- 원인: 설정 문법/권한 문제
- 조치: Caddy 로그 확인 후 `dev-proxy <PORT>` 재실행

### 4) `off --hard` 거부 메시지

- 원인: 보호 포트(예: 22/443/2283) 대상
- 조치: `sudo systemctl stop <service>`로 서비스 단위 정리

## 대안 메모

`tailscale serve`는 커스텀 도메인/TLS 제약으로 현재 운영 경로에서 사용하지 않는다.
