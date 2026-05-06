# nixos-config

macOS와 NixOS 개발 환경을 nix-darwin/NixOS + Home Manager로 선언적 관리하는 프로젝트

## 실행 환경

Environment 섹션의 `Platform` 값으로 현재 환경을 판별한다.

| Platform | 현재 환경 | 다른 머신 접속 |
|----------|----------|---------------|
| `darwin` | Mac | `ssh minipc` |
| `linux` | MiniPC (NixOS) | `ssh mac` |

**현재 환경에 SSH 접속 금지.** Platform: darwin이면 `ssh mac` 금지, linux이면 `ssh minipc` 금지.
현재 NixOS 호스트는 MiniPC 1대뿐이므로 `linux` = MiniPC. 호스트 추가 시 `hostname`으로 구분.

## 빌드

`nrs`를 사용. `darwin-rebuild`/`nixos-rebuild` 직접 실행 금지. `nrs`는 preview를 포함하며, macOS에서는 launchd 정리와 Hammerspoon 재시작도 처리한다. 워크트리에서 `nrs` 완료 시 `$HOME` 아래 out-of-store symlink의 워크트리 relink을 시도한다 (`nrs-relink`, non-fatal). main repo에서 `nrs` 실행 시 nix store 체인으로 복원을 시도한다.

home-manager activation 충돌 정책: macOS에서 mkOutOfStoreSymlink target이 외부 프로세스의 atomic rename으로 일반 파일이 되면 `home-manager.backupCommand`가 자가 치유한다 (regular file은 unlink + 콘솔 한 줄 echo, directory는 timestamped backup). 사이드이펙트로, symlink가 깨진 시간 동안 사용자가 home 쪽에서 의도 변경한 내용도 silent 손실될 수 있다 (예: VSCode UI에서 keybinding 추가 후 settings.json이 깨진 상태에서 한 후속 변경). 정상 symlink 흐름에서는 source 직접 수정 = git 추적이 정상 동작한다. 본 정책은 사용자 명시 동의 범위 내. 정책 본체는 `modules/darwin/home.nix`.

## Bash tool 환경

Bash tool의 inline 스크립트는 zsh에서 실행된다. 아래 bash 전용 문법은 zsh에서 `bad substitution`으로 실패하므로 사용하지 않는다.

| 카테고리 | 금지 예 | zsh-native 대안 |
|---|---|---|
| Associative array 키 열거 | `${!arr[@]}` (typeset -A 대상) | `${(k)arr}` |
| 간접 참조 | `${!var}` | `${(P)var}` |
| Case modification (전체 문자열) | `${var^^}`, `${var,,}` | inline: `${(U)var}`, `${(L)var}`. 할당 속성 (이후 assignment 자동 변환, 표현식 치환 아님): `typeset -u VAR` / `typeset -l VAR` |
| Case modification (첫 글자) | `${var^}`, `${var,}` | `${(U)var:0:1}${var:1}` / `${(L)var:0:1}${var:1}` |

위 표는 카테고리 수준 규칙이다. 표에 없는 bash 전용 문법도 동일 원칙으로 금지 대상이며, 의심되면 `zsh -fc '<표현식>'`으로 실측 확인 후 사용한다.

### macOS BSD vs GNU 도구 라우팅

이 저장소(devShell 자동 활성화)에서는 nix coreutils가 PATH 우선이라, GNU/BSD 옵션 의미가 다른 macOS 시스템 도구를 그냥 호출하면 GNU 도구가 가로채 옵션 미스매치로 실패할 수 있다. macOS BSD 옵션 문법이 필요한 경우 해당 도구의 실제 시스템 경로를 절대경로로 호출한다.

현재 확인된 사례: 파일 mtime epoch — GNU `stat -c %Y file` vs macOS BSD `/usr/bin/stat -f %m file`. 같은 종류의 GNU/BSD 옵션 충돌이 새로 발견되면 같은 단락에 케이스를 추가한다.

## 상수

하드코딩된 IP, 경로, SSH 키, UID의 추가/변경은 `libraries/constants.nix`에서 한다.

## 스킬 문서 불일치 시 행동 원칙

스킬 문서의 CLI 명령이 에러나면 `--help`로 확인 후 차이를 사용자에게 보고.
승인 없이 문서를 우회해 진행하지 않는다.
