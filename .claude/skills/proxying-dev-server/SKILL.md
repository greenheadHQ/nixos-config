---
name: proxying-dev-server
description: |
  This skill should be used when setting up or troubleshooting the dev server
  reverse proxy on NixOS MiniPC.
  Triggers: "dev-proxy 설정", "dev server 프록시", "개발 서버 프록시",
  "dev.greenhead.dev 503 에러", "HMR이 안 됨", "Hot Reload proxy",
  "WebSocket proxy", "dev-proxy off --hard", "모바일 미리보기",
  "iPhone/iPad dev preview".
---

# Dev Server Reverse Proxy (dev.greenhead.dev)

## 목적과 범위

MiniPC에서 실행 중인 로컬 개발 서버를 `https://dev.greenhead.dev`로 HTTPS 프록시하는
운영 절차를 다룬다. 대상은 `dev-proxy` CLI 사용, HMR 점검, 503 복구, Caddy 재로드 문제이다.

## 빠른 참조

| 명령어 | 설명 |
|--------|------|
| `dev-proxy PORT` | 프록시 설정 (`localhost:PORT`) |
| `dev-proxy status` | 현재 upstream 확인 |
| `dev-proxy off` | 프록시 해제(503 복원) |
| `dev-proxy off --hard` | 프록시 해제 + 포트 프로세스 종료 |
| `dp PORT` | 단축 alias |

접속 URL: `https://dev.greenhead.dev` (Tailscale VPN 내부)

## 핵심 절차

1. 개발 서버를 실행한다 (`pnpm run dev`, `next dev`, `nuxt dev` 등).
2. 프록시를 연다: `dev-proxy <PORT>`.
3. 상태를 확인한다: `dev-proxy status`.
4. 모바일/원격 브라우저에서 `https://dev.greenhead.dev` 접속을 확인한다.
5. 작업 종료 시 `dev-proxy off` 또는 `dev-proxy off --hard`를 실행한다.

## 프레임워크별 핵심 설정

### Vite

Vite는 HMR WebSocket 클라이언트 포트를 명시해야 한다.

```typescript
// vite.config.ts
export default defineConfig({
  server: {
    host: '0.0.0.0',
    hmr: {
      host: 'dev.greenhead.dev',
      clientPort: 443,
    },
  },
});
```

### Next.js / Nuxt

- Next.js: `next dev --hostname 0.0.0.0`
- Nuxt: `nuxt dev --host 0.0.0.0`

## FAQ

- **HMR이 안 됨**: Vite `clientPort: 443` 누락 여부를 먼저 확인한다.
- **503 에러**: `dev-proxy status`와 개발 서버 리스닝 상태(`ss -tlnp`)를 확인한다.
- **reload 실패**: `journalctl -u caddy -n 20`로 에러를 확인하고 재적용한다.
- **off --hard 거부**: 시스템 포트는 보호 대상이므로 서비스 단위로 정리한다.

## 참조

- 상세 구조/안전장치/복구 절차: [references/troubleshooting.md](references/troubleshooting.md)
