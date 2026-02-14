---
name: proxying-dev-server
description: |
  Dev server reverse proxy via Caddy HTTPS to dev.greenhead.dev.
  Triggers: "dev-proxy", "dev server", "dev.greenhead.dev",
  "개발 서버", "개발 프록시", "HMR proxy", "Hot Reload",
  "pnpm run dev", "bun run dev", "npm run dev",
  "vite dev", "next dev", "nuxt dev", "localhost 프록시",
  "iPhone dev preview", "모바일 미리보기", "iPad 미리보기",
  "dev 서버 프록시", "웹개발 프리뷰", "개발 서버 호스팅",
  "WebSocket proxy", "wss".
---

# Dev Server Reverse Proxy (dev.greenhead.dev)

MiniPC에서 `pnpm run dev` 등으로 띄운 로컬 개발 서버를
`https://dev.greenhead.dev`로 HTTPS 프록시하여 iPhone/iPad에서 실시간 확인하는 시스템.

기존 Caddy HTTPS + Cloudflare DNS-01 + Tailscale 인프라를 재활용.

## 모듈 구조

| 파일 | 역할 |
|------|------|
| `modules/nixos/programs/dev-proxy/default.nix` | 핵심 모듈 (activationScripts + init + Caddy vhost + 스크립트) |
| `modules/nixos/options/homeserver.nix` | `devProxy` mkOption 정의 |
| `modules/nixos/lib/caddy-security-headers.nix` | Caddy 공통 보안 헤더 (caddy.nix과 공유) |
| `modules/nixos/programs/caddy.nix` | Caddy 메인 설정 (보안 헤더 공유, 기존 서비스 vhost) |
| `libraries/constants.nix` | `domain.subdomains.dev = "dev"` |

## 사용법

```bash
dev-proxy 5173       # 포트 프록시 설정 → dev.greenhead.dev → localhost:5173
dev-proxy status     # 현재 upstream 설정 표시
dev-proxy off        # 프록시 해제 (503 복원, 서버 프로세스 유지)
dev-proxy off --hard # 프록시 해제 + 해당 포트 프로세스도 종료 (시스템 포트는 거부)
dp 5173              # 단축 alias (dp = dev-proxy)
```

접속 URL: `https://dev.greenhead.dev` (Tailscale VPN 내에서만)

## HMR/Hot Reload 프레임워크별 설정

### Vite (가장 중요)

Vite는 HMR WebSocket 연결 시 `location.host`를 사용하는데,
리버스 프록시 뒤에서는 `clientPort: 443`을 명시해야 합니다.

```typescript
// vite.config.ts
export default defineConfig({
  server: {
    host: '0.0.0.0',  // 권장 (모든 인터페이스 바인딩)
    hmr: {
      host: 'dev.greenhead.dev',
      clientPort: 443,  // 필수! Caddy HTTPS 포트
    },
  },
});
```

**`clientPort: 443` 없으면 HMR이 동작하지 않습니다** (Vite dev server 포트로 직접 연결 시도).

### Next.js

기본적으로 `location.host`를 사용하므로 대부분 추가 설정 불필요.

```bash
next dev --hostname 0.0.0.0  # 권장
```

### 기타 프레임워크 (Nuxt, SvelteKit 등)

```bash
# --host 0.0.0.0 권장 (필수 아님 — Caddy가 localhost로 프록시)
nuxt dev --host 0.0.0.0
```

### 공통 사항

- Caddy v2 `reverse_proxy`가 WebSocket Upgrade 헤더를 자동 프록시 (별도 설정 불필요)
- `--host 0.0.0.0`은 권장 (HMR 클라이언트 이슈 예방)

## 작동 원리

1. `dev-proxy PORT` 실행 → `/run/caddy/dev-upstream`에 `reverse_proxy localhost:PORT` 쓰기
2. `sudo systemctl reload caddy` → Caddy가 `import /run/caddy/dev-upstream` 재해석
3. `dev.greenhead.dev` 요청 → Caddy가 `localhost:PORT`로 프록시

비활성 상태: `respond "No dev server running" 503`

### 안전장치

- **원자적 쓰기**: `mktemp` + `mv` + `trap EXIT` (부분 쓰기/중단 시 임시파일 정리)
- **포트 검증**: 숫자 + 범위(1-65535) — Caddy 디렉티브 인젝션 방지
- **시스템 포트 보호**: `off --hard`에서 22(ssh), 443(caddy), 2283(immich) 등 시스템 서비스 포트는 kill 거부
- **Reload 실패 복원**: Caddy reload 실패 시 이전 상태 자동 복원 + 에러 메시지 표시
- **부팅 초기화**: `activationScripts` + `caddy-dev-init` oneshot으로 파일 보장
- **모듈 의존성**: `homeserver.reverseProxy.enable` 필수 — assertion으로 빌드 시 검증

## 개발 서버 프로세스 관리 팁

`off --hard`는 먼저 503으로 전환 + Caddy reload 후 프로세스를 kill합니다.
(502 Bad Gateway 노출 없이 바로 503 → 프로세스 정리 순서)

```bash
# 현재 리스닝 포트 확인
ss -Htn4 state listening

# 프록시 해제 + 포트 프로세스 종료 (가장 간편)
dev-proxy off --hard

# 백그라운드 dev 서버 실행 (tmux/nohup)
nohup pnpm run dev &
dev-proxy 5173

# 정리
dev-proxy off --hard  # 프록시 해제 + pnpm dev 프로세스 종료
```

## Tailscale Serve 대안

`tailscale serve --bg PORT`로 간편하게 프록시할 수 있지만:

- 커스텀 도메인 미지원 (`*.ts.net`만 가능)
- 현재 무료 플랜에서 TLS 인증서 발급 불가 (`tailscale cert` 실패 확인)
- 현재 tailnet에서 Serve 기능 비활성화 상태

→ Caddy 방식 채택.

## Known Issues + FAQ

**HMR 안 됨 (Vite)**
→ `vite.config.ts`에서 `server.hmr.clientPort: 443` 확인. 이 설정 없으면 HMR WebSocket이 dev server 포트로 직접 연결 시도.

**503 에러**
→ `dev-proxy status` 또는 `cat /run/caddy/dev-upstream` 확인. 개발 서버가 실행 중인지 `ss -tlnp | grep PORT`로 확인.

**Caddy reload 실패**
→ 에러 메시지가 터미널에 직접 표시됨. 추가 확인: `sudo journalctl -u caddy -n 20`.
dev-proxy 스크립트가 이전 상태를 자동 복원하므로 기존 서비스에는 영향 없음.

**`/run/caddy/dev-upstream` 파일 없음**
→ `dev-proxy status`가 친절한 에러 메시지 표시. 수동 복구: `sudo systemctl start caddy-dev-init`.
정상 상태에서는 `activationScripts` + oneshot이 자동 생성.

**`off --hard`에서 "Refusing to kill" 메시지**
→ 시스템 서비스 포트(22, 443, 2283, 3002, 3003, 3923, 8222, 27701)는 안전장치로 kill이 거부됨.
해당 포트의 프로세스를 정리하려면 직접 `sudo systemctl stop <service>` 사용.

**`devProxy.enable = true`인데 빌드 실패 — assertion error**
→ `homeserver.reverseProxy.enable = true`도 함께 설정해야 함. devProxy는 Caddy(reverseProxy)에 의존.

## 빠른 참조

| 명령어 | 설명 |
|--------|------|
| `dev-proxy PORT` | 프록시 설정 |
| `dev-proxy off` | 프록시 해제 (503 복원) |
| `dev-proxy off --hard` | 프록시 해제 + 포트 프로세스 종료 |
| `dev-proxy status` | 현재 upstream 확인 |
| `dp PORT` | 단축 alias |
| `cat /run/caddy/dev-upstream` | upstream 파일 직접 확인 |
| `sudo journalctl -u caddy -n 20` | Caddy 로그 |
| `ss -Htn4 state listening` | 리스닝 포트 확인 |

## LLM 지침

- MiniPC에서 `pnpm run dev` 등 실행 시 `dev-proxy PORT` 사용을 안내
- Vite 프로젝트면 `server.hmr.clientPort: 443` 설정을 반드시 포함
- `--host 0.0.0.0`은 권장 (HMR 클라이언트 이슈 예방)
- 접속 URL: `https://dev.greenhead.dev` (Tailscale 필수)
