# nixos-config

[English](./README.md)

개인용 Mac, 업무용 Mac, NixOS 홈서버의 Nix 설정입니다. 머신마다 환경이 달라지는 것을 줄이고, 필요할 때 다시 구성하기 쉽게 하려고 한곳에서 관리합니다.

Mac에는 nix-darwin을 쓰고, macOS와 NixOS의 사용자 설정은 Home Manager로 관리합니다. 셸·에디터·CLI 설정은 공유하고, 데스크톱 앱과 서버 서비스는 별도 모듈로 나눴습니다.

제 사용자명, 경로, 암호화된 시크릿이 포함된 개인 설정입니다. 필요한 부분이 있다면 개별 모듈부터 살펴보세요.

## 구성

[flake.nix](./flake.nix)에 Apple Silicon Mac 두 대와 x86_64 Linux 서버를 정의합니다. 호스트 역할을 개인용·업무용·서버로 구분해서, 개인용 Mac의 앱을 업무용 머신에서는 제외하는 식으로 설정을 나눕니다.

| 위치 | 내용 |
| --- | --- |
| [modules/shared](./modules/shared/) | 머신 간에 공유하는 셸, Git, Neovim, tmux 등의 설정 |
| [modules/darwin](./modules/darwin/) | macOS 환경설정, 데스크톱 앱, 자동화 |
| [modules/nixos](./modules/nixos/) | NixOS 시스템 설정과 홈서버 서비스 |
| [hosts](./hosts/) | 하드웨어와 디스크 구성 |
| [libraries/constants.nix](./libraries/constants.nix) | 공통 호스트·네트워크·경로 값 |

시스템 패키지와 설정은 Nix로 관리합니다. Node.js와 패키지 매니저는 프로젝트마다 버전을 선택할 수 있도록 [mise](./modules/shared/programs/mise/)로 관리합니다. 일부 Mac 앱은 [Homebrew](./modules/darwin/programs/homebrew.nix)로 선언합니다.

## 살펴볼 만한 설정

**Mac 자동화.** [Hammerspoon](./modules/darwin/programs/hammerspoon/)으로 입력 소스 전환, 한글 입력 중 터미널 단축키 처리, Finder의 현재 폴더에서 Ghostty 열기를 구현했습니다. [폴더 액션](./modules/darwin/programs/folder-actions/)은 launchd로 비디오 압축과 GIF 변환을 처리하고, 개인용 Mac에서는 스크린샷을 Immich에 업로드합니다.

**홈서버와 Anki.** MiniPC에는 사진용 Immich, 북마크용 Karakeep, 파일용 Copyparty 설정이 있습니다. [홈서버 옵션](./modules/nixos/options/homeserver.nix)으로 서비스를 구성하고 [NixOS 설정](./modules/nixos/configuration.nix)에서 활성화합니다. [Anki 호스트](./modules/nixos/programs/anki-host/README.md)에는 동기화, 백업, 채팅 앱에서 노트를 조회하고 수정하는 MCP 서버가 포함되어 있습니다.

**Claude Code와 Codex.** [Claude](./modules/shared/programs/claude/)와 [Codex](./modules/shared/programs/codex/) 모듈에서 설정, 훅, 공통 스킬을 관리합니다. [저장소 전용 스킬](./.claude/skills/)에는 이 환경을 관리하는 절차를 두어, 설정과 함께 유지합니다.

## 설정 변경과 검증

저장소 루트에서 다음 명령으로 검사합니다.

```sh
nix develop --command bash tests/run-all-tests.sh
```

[테스트 실행 스크립트](./tests/run-all-tests.sh)는 [CI](./.github/workflows/check.yml)에서도 사용합니다. Git 훅 동작은 [Nix 운영 문서](./.claude/skills/understanding-nix/references/features.md#pre-commit-hooks)에, 실행 명령과 조건은 [lefthook.yml](./lefthook.yml)에 있습니다.

이 설정이 이미 설치된 머신에서는 `nrs`로 변경 사항을 미리 보고 적용합니다. [macOS](./.claude/skills/managing-macos/SKILL.md), [MiniPC](./.claude/skills/managing-minipc/SKILL.md), [시크릿 관리](./.claude/skills/managing-secrets/SKILL.md) 절차는 각 운영 문서에 있습니다. 운영 문서와 코드 주석은 주로 한국어로 작성합니다.

[MIT 라이선스](./LICENSE).
