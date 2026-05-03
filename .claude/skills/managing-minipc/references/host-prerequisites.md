# Host Prerequisites — NixOS MiniPC (Podman-backed hosting 공유)

본 reference는 hosting-{copyparty,karakeep,vaultwarden} skill (Podman-backed hosting 3종) 절차의 공통 NixOS MiniPC 호스트 환경 전제다. AI 에이전트 세션(Claude Code · Codex CLI · headless)이 어디서 실행되든 다음 의존을 충족하지 못하면 명령은 실행 불가하다.

## 공통 의존

- `sudo`로 systemd/podman 명령 실행 (호스트 sudoers 등록 필요)
- Tailscale VPN 내부에서 `https://*.greenhead.dev` 도달
- agenix가 호스트의 identity key(`/home/<user>/.ssh/id_ed25519`)로 복호화한 secret 파일 접근 (배포된 `/run/agenix/*` 읽기는 sudo 필요)
- agenix CLI로 `<name>.age` 편집 (sudo 불필요. agenix는 cwd의 `./secrets.nix`를 RULES로 로드하므로 `secrets/` 디렉토리에서 실행)
  - canonical: `cd secrets && agenix -e <name>.age` (PATH `agenix` 사용 가능 시)
  - fallback: `cd secrets && nix run github:ryantm/agenix -- -e <name>.age`
- Podman socket 접근 권한 + 각 서비스별 `podman-<service>.service` systemd unit 관리

본 스킬을 macOS Codex 세션 등 다른 호스트에서 호출하면 명령이 작동하지 않는다.

## Owner

managing-minipc는 NixOS MiniPC 호스트 자체 관리 owner. 본 reference는 hosting-copyparty/karakeep/vaultwarden (Podman-backed hosting 3종)이 consumer. hosting-anki는 systemd native + Tailscale IP(`http://100.79.80.95:27701/`) 패턴이라 본 SSOT 범위 외.
