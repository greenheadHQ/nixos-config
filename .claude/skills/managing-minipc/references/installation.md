# NixOS MiniPC 설치/복구 가이드

## 목차

- [시스템 정보](#시스템-정보)
- [디스크 레이아웃](#디스크-레이아웃)
- [재설치 시 핵심 단계](#재설치-시-핵심-단계)
- [설치 후 검증 체크리스트](#설치-후-검증-체크리스트)
- [Mac에서의 후속 설정](#mac에서의-후속-설정)
- [복구 방법](#복구-방법)
- [주요 설정 파일](#주요-설정-파일)

---

## 시스템 정보

| 항목 | 값 |
|------|-----|
| 호스트명 | greenhead-minipc |
| 사용자 | greenhead |
| Tailscale IP | 100.79.80.95 (`libraries/constants.nix`의 `network.minipcTailscaleIP`) |
| SSH 접속 | `ssh minipc` |

---

## 디스크 레이아웃

```
NVMe (476.9GB) - /dev/nvme0n1
├── nvme0n1p1: 512MB  vfat  /boot
├── nvme0n1p2: 8GB    swap  [SWAP]
└── nvme0n1p3: 468GB  ext4  /

HDD (1.8TB) - /dev/sda
└── sda1: 1.8TB ext4 → /mnt/data (⚠️ 보존!)
```

> 파티션 번호 순서는 disko가 정한다 — `size = "100%"`인 root가 마지막으로 밀리므로 p2가 swap, p3가 `/`다.
> 루트를 손으로 마운트할 때 p2를 쓰면 swap을 마운트하려다 실패한다 (실기 `lsblk` 대조 확인, 2026-09).

> 경고: HDD(/dev/sda)에는 295GB의 미디어 데이터가 있습니다. 재설치 시 절대 포맷하지 마세요.

---

## 재설치 시 핵심 단계

### 1. NixOS Live USB 부팅 및 디스크 확인

```bash
sudo -i
lsblk -o NAME,SIZE,MODEL,TYPE,MOUNTPOINTS
```

확인 게이트 1 — 아래 표와 출력을 눈으로 대조한 뒤에만 다음 단계로 넘어간다.

| 장치 | 크기 | 처리 |
|------|------|------|
| `nvme0n1` | 476.9G | 포맷 대상 (NixOS) |
| `sda` | 1.8T | 보존 (미디어 데이터) |

`sda`가 출력에 없거나 크기·모델이 다르면 중단한다. 디스크 순서가 바뀐 상태에서 파티셔닝하면 미디어 디스크를 지운다.

### 2. disko로 NVMe 파티셔닝

disko 설정은 flake에 이미 배선돼 있다 (`hosts/greenhead-minipc/default.nix`가 `disko.nix`를 import하고, `flake.nix`가 `disko.nixosModules.disko`를 포함). 따라서 disko.nix 파일을 개별 URL로 내려받지 않고 저장소를 그대로 지정한다 — 저장소 안에서 파일 경로가 바뀌어도 이 절차는 따라간다.

확인 게이트 2 — 파티셔닝은 되돌릴 수 없다. 아래 명령을 먼저 실행해 disko가 어떤 device를 대상으로 하는지 직접 읽은 뒤에만 다음 블록으로 넘어간다.

```bash
nix-shell -p git --run 'git clone https://github.com/greenheadHQ/nixos-config /tmp/nixos-config'
grep -n 'device = ' /tmp/nixos-config/hosts/greenhead-minipc/disko.nix
# /dev/nvme0n1 한 줄만 나와야 한다. /dev/sda가 섞여 있으면 즉시 중단.
```

게이트를 통과했으면 방금 읽은 그 파일을 그대로 넘겨 파티셔닝한다 (확인한 내용과 실행하는 내용을 일치시키기 위해 flake 지정보다 로컬 경로를 우선한다).

```bash
nix --experimental-features "nix-command flakes" run github:nix-community/disko -- \
  --mode destroy,format,mount /tmp/nixos-config/hosts/greenhead-minipc/disko.nix
```

clone 없이 flake를 직접 지정할 수도 있다. 이때는 게이트 2를 GitHub 웹에서 `hosts/greenhead-minipc/disko.nix`를 열어 대신한다.

```bash
nix --experimental-features "nix-command flakes" run github:nix-community/disko -- \
  --mode destroy,format,mount --flake github:greenheadHQ/nixos-config#greenhead-minipc
```

> `--mode destroy,format,mount`는 대상 디스크의 파티션 테이블을 지우고 다시 만든다. 예전 문서의 `--mode disko`는 같은 동작의 legacy alias이며 상위 저장소가 현재 이름을 권장한다.
> 옵션 이름은 disko 릴리스마다 바뀔 수 있으니 실행 전에 `nix run github:nix-community/disko -- --help`로 한 번 확인한다 (2026-09 기준 문서 표기, 실행 미실측 — 근거: https://github.com/nix-community/disko).

### 3. NixOS 설치

```bash
nixos-install --flake github:greenheadHQ/nixos-config#greenhead-minipc
```

> root 비밀번호 옵션: 퇴역한 설치 스크립트(2026-09 삭제)는 옵션 없이(설치 중 root 비밀번호를 입력하는 방식) 실행했고, 이 문서는 `--no-root-passwd`를 달고 있어 두 사본이 갈려 있었다. 스크립트 값을 채택해 옵션 없는 형태로 적는다 (운영자 확인 대기). 무인 설치로 되돌리기로 결정하면 `--no-root-passwd`를 다시 붙이고 이 문단을 갱신한다.

### 4. 재부팅 후 초기 설정

설치가 끝나면 `reboot` 후 greenhead 사용자로 로그인한다.

```bash
sudo tailscale up   # 출력되는 URL로 인증
tailscale ip -4     # Mac 쪽 설정에 필요한 Tailscale IP 확인
```

#### GitHub 접근용 SSH 키 생성·등록

재설치한 호스트에는 이전 키가 남아 있지 않으므로 새로 만든다.

```bash
[[ -f ~/.ssh/id_ed25519 ]] || ssh-keygen -t ed25519 -C "greenhead@minipc" -N "" -f ~/.ssh/id_ed25519
cat ~/.ssh/id_ed25519.pub
```

출력한 공개키를 GitHub 계정 설정(Settings → SSH and GPG keys → New SSH key)에 등록하고 접속을 확인한다.

```bash
ssh -T git@github.com   # "successfully authenticated" 문구 확인
```

> 이 사용자 키와 재생성된 host key(`/etc/ssh/ssh_host_ed25519_key.pub`)는 `libraries/constants.nix`의 `sshKeys.minipc`·`hostKeys.minipc`가 단일 소스다. 값이 달라졌으면 constants를 갱신하고 그 키를 recipient로 쓰는 agenix 시크릿을 재암호화해야 한다 (절차는 `managing-secrets` 스킬).

#### hardware-configuration.nix 교체

`nixos-install`이 실기에서 생성한 하드웨어 감지 결과를 저장소에 반영하는 단계다. 빼먹으면 이후 `nrs`가 이전 하드웨어 전제로 빌드된다.

clone 위치는 `~/Workspace/nixos-config`로 고정한다. `flake.nix`의 `workspaceDir`(118-119행)가 이 경로로 `nixosConfigPath`를 만들고 Home Manager의 `mkOutOfStoreSymlink` 타깃들이 그 값을 그대로 쓰기 때문에, 다른 곳에 clone하면 `nrs` 후 홈 디렉토리 심링크가 전부 dangling이 된다 (사용처 확인: `git grep -n nixosConfigPath`).

```bash
git clone git@github.com:greenheadHQ/nixos-config.git ~/Workspace/nixos-config
cd ~/Workspace/nixos-config
diff /etc/nixos/hardware-configuration.nix hosts/greenhead-minipc/hardware-configuration.nix
```

diff가 비어 있으면 교체할 것이 없다. 차이가 있으면 실기 값을 채택한다.

```bash
cp /etc/nixos/hardware-configuration.nix hosts/greenhead-minipc/
```

복사본에는 `fileSystems."/"`·`fileSystems."/boot"`·`swapDevices`가 들어 있는데 이 항목들은 disko가 관리하므로 중복이다. 해당 줄을 지우고 저장소 주석(`# fileSystems ... are managed by disko.nix`)을 유지한 뒤 커밋·푸시한다.

```bash
git add hosts/greenhead-minipc/hardware-configuration.nix
git commit -m "feat(minipc): 실기 hardware-configuration.nix 반영"
git push
```

> 이 호스트에서 처음 커밋한다면 author 정보가 없어 커밋이 실패한다. 첫 `nrs` 전이라 Home Manager가 배포하는 `~/.config/git/config`도 아직 없으므로 이 저장소에만 적용되는 `--local`로 채운다 — `--global`이 만드는 `~/.gitconfig`는 git이 XDG 설정보다 나중에 읽어서, 이후 Home Manager가 관리하는 값을 계속 덮어쓴다.
>
> ```bash
> git config --local user.name greenhead
> git config --local user.email <GitHub 계정 이메일>
> ```

#### 시스템 적용

```bash
cd ~/Workspace/nixos-config && nrs
```

---

## 설치 후 검증 체크리스트

| 확인 항목 | 명령 | 기대 결과 |
|-----------|------|-----------|
| 시스템/커널 | `uname -a`, `nixos-version` | 설치한 NixOS 버전 |
| 파티션·마운트 | `lsblk -o NAME,SIZE,MOUNTPOINTS`, `swapon --show` | nvme0n1에 `/boot`·`/`·swap, sda1에 `/mnt/data` |
| HDD 데이터 보존 | `ls /mnt/data` | 재설치 전 미디어 데이터가 그대로 존재 |
| 서비스 상태 | `systemctl --failed` | 실패 유닛 0개 |
| Tailscale | `tailscale status` | 온라인, IP가 `constants.network.minipcTailscaleIP`와 일치 |
| 개발 도구 | `tmux -V`, `atuin status`, `claude --version` | 각 명령이 버전/상태를 출력 |
| Mac에서 접속 | (Mac에서) `ssh minipc` | 접속 성공 |

> 파티션 번호(p1/p2/p3)는 disko가 만드는 순서에 달려 있으므로 문서 값을 믿지 말고 `lsblk` 출력을 그대로 읽는다. 아래 복구 절차의 장치 이름도 이 출력으로 대조한 뒤 사용한다.

`tailscale ip -4` 값이 constants와 다르면 constants를 갱신하고 Mac에서 `nrs`를 실행해야 `ssh minipc`가 붙는다.

---

## Mac에서의 후속 설정

Mac의 `~/.ssh/config`는 Home Manager가 소유한다 (`modules/darwin/programs/ssh/default.nix`의 `programs.ssh.settings`). 손으로 편집하면 심링크가 깨지고 다음 `nrs`에서 되돌아가므로, minipc 접속 설정은 그 모듈과 `libraries/constants.nix`에서만 바꾼다.

재설치로 host key가 바뀌면 첫 접속이 host key 불일치로 거부된다. 기존 항목을 지운 뒤 다시 접속한다.

```bash
ssh-keygen -R "$(ssh -G minipc | awk '/^hostname /{print $2}')"
ssh minipc
```

Atuin shell history를 새 호스트로 이어가려면 encryption key를 옮겨야 한다. 절차는 `syncing-atuin` 스킬의 [새 호스트로 encryption key 이관](../../syncing-atuin/references/troubleshooting.md#새-호스트로-encryption-key-이관)을 따른다.

---

## 복구 방법

### 부팅 실패 시

1. systemd-boot 메뉴에서 이전 세대 선택
2. 또는 Live USB로 부팅 후:

```bash
mount /dev/nvme0n1p3 /mnt   # p2는 swap
mount /dev/nvme0n1p1 /mnt/boot
nixos-enter
nixos-rebuild switch --rollback
```

### 세대 관리

```bash
# 세대 목록
nix-env --list-generations -p /nix/var/nix/profiles/system

# 롤백
sudo nixos-rebuild switch --rollback

# 가비지 컬렉션
nix-collect-garbage -d
```

---

## 주요 설정 파일

| 파일 | 용도 |
|------|------|
| `hosts/greenhead-minipc/default.nix` | 호스트 설정 |
| `hosts/greenhead-minipc/disko.nix` | 디스크 파티셔닝 |
| `hosts/greenhead-minipc/hardware-configuration.nix` | 하드웨어 설정 |
| `modules/nixos/configuration.nix` | NixOS 공통 설정 |
