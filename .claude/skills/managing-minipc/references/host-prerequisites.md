# Host Prerequisites — NixOS MiniPC (Podman-backed hosting 공유)

본 reference는 hosting-{copyparty,karakeep} skill (Podman-backed hosting 2종) 절차의 공통 NixOS MiniPC 호스트 환경 전제다. AI 에이전트 세션(Claude Code · Codex CLI · headless)이 어디서 실행되든 다음 의존을 충족하지 못하면 명령은 실행 불가하다.

## 공통 의존

- `sudo`로 systemd/podman 명령 실행 (호스트 sudoers 등록 필요)
- Tailscale VPN 내부에서 `https://*.greenhead.dev` 도달
- agenix가 호스트의 identity key(`/home/<user>/.ssh/id_ed25519`)로 복호화한 secret 파일 접근 (배포된 `/run/agenix/*` 읽기는 sudo 필요)
- agenix CLI로 `<name>.age` 편집 (사용자 키 항목은 sudo 불필요). 저장소 루트에서 `nix develop`에 진입해 `flake.lock`에 고정된 agenix를 사용한다.
  - `cd secrets && AGENIX_RULES="$PWD/secrets.nix" agenix -e <name>.age`로 기존 규칙 파일을 명시한다.
  - 호스트 키 항목의 sudo 환경·절대 CLI 경로와 값 보존 확인은 [managing-secrets 워크플로](../../managing-secrets/references/workflows.md)의 "명령 준비"와 "호스트 추가"를 따른다.
- Podman socket 접근 권한 + 각 서비스별 `podman-<service>.service` systemd unit 관리

본 스킬을 macOS Codex 세션 등 다른 호스트에서 호출하면 명령이 작동하지 않는다.

## Owner

managing-minipc는 NixOS MiniPC 호스트 자체 관리 owner. 본 reference는 hosting-copyparty/karakeep (Podman-backed hosting 2종)이 consumer.
