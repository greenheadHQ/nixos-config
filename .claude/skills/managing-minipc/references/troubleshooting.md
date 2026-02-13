# 트러블슈팅

NixOS MiniPC 관련 문제와 해결 방법을 정리합니다.

## 목차

- [nixos-install 시 GitHub flake 캐시 문제](#nixos-install-시-github-flake-캐시-문제)
- [disko.nix와 hardware-configuration.nix fileSystems 충돌](#diskonix와-hardware-configurationnix-filesystems-충돌)
- [첫 로그인 시 zsh-newuser-install 화면](#첫-로그인-시-zsh-newuser-install-화면)
- [한글이 ■로 표시됨 (locale 미설정)](#한글이-로-표시됨-locale-미설정)
- [nixos-rebuild 실패로 인한 시스템 부팅 불가](#nixos-rebuild-실패로-인한-시스템-부팅-불가)

---

## nixos-install 시 GitHub flake 캐시 문제

> **발생 시점**: 2026-01-17 (MiniPC NixOS 설치)

**증상**: `flake.nix`를 수정하고 GitHub에 push한 후 `nixos-install --flake github:user/repo#host`를 실행해도 이전 버전이 사용됨.

```bash
$ nixos-install --flake github:shren207/nixos-config#greenhead-minipc
# 에러: 방금 수정한 내용이 반영되지 않음
```

**원인**: GitHub의 flake 참조는 캐싱됩니다. `--refresh` 옵션이 `nixos-install`에는 없습니다.

**해결**: 로컬에 clone해서 설치

```bash
# GitHub URL 대신 로컬 clone 사용
git clone https://github.com/user/nixos-config.git /tmp/nixos-config
nixos-install --flake /tmp/nixos-config#hostname
```

**왜 발생하는가?**

| 방식 | 캐싱 | 해결책 |
|------|------|--------|
| `github:user/repo` | GitHub API 캐시 | 로컬 clone 사용 |
| `/tmp/nixos-config` | 없음 (로컬) | 최신 상태 보장 |

> **참고**: `nix build`나 `nix develop`에서는 `--refresh` 옵션으로 캐시를 무시할 수 있지만, `nixos-install`은 이 옵션을 지원하지 않습니다.

---

## disko.nix와 hardware-configuration.nix fileSystems 충돌

> **발생 시점**: 2026-01-17 (MiniPC NixOS 설치)

**증상**: `nixos-rebuild switch` 실행 시 fileSystems 충돌 에러.

```
error: The option `fileSystems."/".device` has conflicting definition values:
- In `module.nix': "/dev/disk/by-partlabel/disk-nvme-root"
- In `hardware-configuration.nix': "/dev/disk/by-uuid/xxx"
```

**원인**: disko.nix가 파티션과 마운트를 관리하는데, `nixos-generate-config`로 생성된 hardware-configuration.nix에도 동일한 fileSystems 정의가 있어서 충돌.

**해결**: hardware-configuration.nix에서 disko가 관리하는 항목 제거

```nix
# 변경 전 (hardware-configuration.nix)
fileSystems."/" = { device = "/dev/disk/by-uuid/xxx"; fsType = "ext4"; };
fileSystems."/boot" = { device = "/dev/disk/by-uuid/yyy"; fsType = "vfat"; };
swapDevices = [ { device = "/dev/disk/by-uuid/zzz"; } ];
fileSystems."/mnt/data" = { device = "/dev/disk/by-uuid/aaa"; fsType = "ext4"; };  # HDD

# 변경 후
# fileSystems."/" and "/boot" are managed by disko.nix
# swapDevices are managed by disko.nix

# HDD mount (disko가 관리하지 않는 것만 유지)
fileSystems."/mnt/data" = { device = "/dev/disk/by-uuid/aaa"; fsType = "ext4"; };
```

**핵심 원칙**:

| 항목 | 관리 주체 | hardware-configuration.nix |
|------|-----------|---------------------------|
| `/` (root) | disko.nix | 제거 |
| `/boot` (ESP) | disko.nix | 제거 |
| swap | disko.nix | 제거 |
| `/mnt/data` (추가 디스크) | hardware-configuration.nix | 유지 |

---

## 첫 로그인 시 zsh-newuser-install 화면

> **발생 시점**: 2026-01-17 (MiniPC NixOS 설치)

**증상**: 새 사용자로 처음 로그인할 때 zsh 설정 마법사가 나타남.

```
This is the Z Shell configuration function for new users,
zsh-newuser-install.
You are seeing this message because you have no zsh startup files
(the files .zshenv, .zprofile, .zshrc, .zlogin in the directory
~). This function can help you with a few settings that should
make your use of the shell easier.

You can:
(q) Quit and do nothing.
(0) Exit, creating the file ~/.zshrc containing just a comment.
(1) Continue to the main menu.
```

**원인**: Home Manager가 아직 적용되지 않아서 `.zshrc` 파일이 없음.

**해결**: `0` 입력 (빈 .zshrc 생성)

```
---- Type one of the keys in parentheses ---- 0
```

**왜 0을 선택하는가?**

| 선택 | 결과 | 권장 |
|------|------|------|
| `q` | 다음 로그인에도 다시 나타남 | X |
| `0` | 빈 `.zshrc` 생성 -> 다시 안 나타남 | O |
| `1` | 수동 설정 -> Home Manager와 충돌 가능 | X |

Home Manager가 나중에 `.zshrc`를 관리하므로, 지금은 빈 파일로 넘어가면 됩니다.

---

## 한글이 ■로 표시됨 (locale 미설정)

> **발생 시점**: 2026-01-17 (MiniPC NixOS 설치)

**증상**: NixOS 설치 직후 터미널에서 한글이 ■(검은 사각형)으로 표시됨.

```
[sudo] greenhead ■ ■ :
■ ■ ■ ■ ■ ■ ■ ■ .
```

**원인**:

1. 콘솔 폰트가 한글을 지원하지 않음
2. locale이 아직 완전히 적용되지 않음

**해결**: 이것은 **TTY 콘솔의 정상적인 제한사항**입니다.

- TTY(가상 콘솔)는 유니코드 글꼴 지원이 제한적
- SSH로 접속하거나 GUI 터미널을 사용하면 정상 표시됨

**확인**:

```bash
# locale 설정 확인
$ locale
LANG=en_US.UTF-8

# SSH로 접속하면 정상
$ ssh user@minipc
# 한글 정상 표시됨
```

**참고**: NixOS configuration에서 locale이 올바르게 설정되어 있다면 문제없습니다.
(설치 직후 `ko_KR.UTF-8`에서 `en_US.UTF-8`로 변경됨)

```nix
# modules/nixos/configuration.nix
i18n.defaultLocale = "en_US.UTF-8";
```

---

## nixos-rebuild 실패로 인한 시스템 부팅 불가

**날짜**: 2026-01-21

**증상**: `nixos-rebuild switch` 실행 후 서비스가 사라짐

```bash
# 재부팅 후 서비스가 존재하지 않음
Failed to restart tailscaled.service: Unit tailscaled.service not found.
Failed to stop podman-immich-server.service: Unit podman-immich-server.service not loaded.
```

**원인**: nixos-rebuild 과정에서 빌드 실패로 불완전한 시스템 설정이 생성되었고, 이 세대로 부팅하면 대부분의 서비스가 없는 상태가 됨.

**해결**:

1. 모니터/키보드로 직접 접속하여 이전 세대로 롤백:
```bash
# 방법 1: 명령으로 롤백
sudo nixos-rebuild switch --rollback

# 방법 2: 세대 목록 확인 후 특정 세대로 전환
sudo nix-env --list-generations --profile /nix/var/nix/profiles/system
sudo /nix/var/nix/profiles/system-29-link/bin/switch-to-configuration switch
```

2. 또는 재부팅 시 systemd-boot 메뉴에서 이전 세대 선택

**교훈**:

- 빌드 실패 시 switch를 진행하지 않도록 주의
- 불완전한 세대가 생성되면 롤백으로 복구 가능 (NixOS의 장점)
