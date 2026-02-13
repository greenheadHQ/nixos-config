# 트러블슈팅

## SSH/인증 관련

### 재부팅 후 SSH 키가 ssh-agent에 로드되지 않음

> **발생 시점**: 2026-01-15
> **해결**: launchd agent + nrs.sh 자동 로드

**증상**: 재부팅 후 `nrs` 또는 `darwin-rebuild switch` 실행 시 GitHub SSH fetch 실패.

```
error: Failed to fetch git repository ssh://git@github.com/... : git@github.com: Permission denied (publickey).
```

**원인**: macOS의 `ssh-agent`는 재부팅 시 SSH 키를 자동으로 로드하지 않습니다.

```bash
# 재부팅 후 확인
$ ssh-add -l
The agent has no identities.  # ← 키가 없음!

# 일반 ssh 명령은 작동 (macOS Keychain 직접 참조)
$ ssh -T git@github.com
Hi shren207! You've successfully authenticated...
```

nix-daemon은 별도 프로세스로 실행되어 Keychain에 직접 접근하지 못하고, `ssh-agent`만 사용합니다.

**해결**: 두 가지 방법으로 자동화

1. **launchd agent** (`com.green.ssh-add-keys`): 로그인 시 자동으로 `ssh-add` 실행
2. **nrs.sh**: darwin-rebuild 전에 키 로드 여부 확인

**설정 파일**: `modules/darwin/programs/ssh/default.nix`

```nix
# launchd agent - 로그인 시 SSH 키 자동 로드
launchd.agents.ssh-add-keys = {
  enable = true;
  config = {
    Label = "com.green.ssh-add-keys";
    ProgramArguments = [ "${sshAddScript}" ];
    RunAtLoad = true;
    EnvironmentVariables = { HOME = homeDir; };
  };
};
```

**확인 방법**:

```bash
# SSH agent에 키 로드 확인
ssh-add -l

# launchd agent 상태 확인
launchctl list | grep ssh-add

# 로그 확인
cat ~/Library/Logs/ssh-add-keys.log
```

macOS의 `AddKeysToAgent yes` 설정은 SSH를 **처음 사용할 때** 키를 agent에 로드합니다. 재부팅 후 바로 SSH 작업을 하면 키가 로드되지 않은 상태일 수 있습니다.

> **참고**: SSH 키 자동 로드는 launchd agent에서 처리됩니다.

---

### sudo 사용 시 SSH 인증 실패

**에러 메시지**:
```
warning: $HOME ('/Users/glen') is not owned by you, falling back to the one defined in the 'passwd' file ('/var/root')
git@github.com: Permission denied (publickey).
```

**원인**: `sudo`로 실행하면 root 사용자로 전환되어 현재 사용자의 SSH 키(`~/.ssh/id_ed25519`)에 접근할 수 없습니다.

**해결**: SSH agent를 사용하여 키를 메모리에 로드하고, `sudo` 실행 시 `SSH_AUTH_SOCK` 환경변수를 유지합니다:

```bash
# 1. SSH agent에 키 추가
ssh-add ~/.ssh/id_ed25519

# 2. SSH_AUTH_SOCK 환경변수를 유지하면서 sudo 실행
sudo --preserve-env=SSH_AUTH_SOCK <command>
```

**왜 sudo가 필요한가?**

nix-darwin/NixOS는 시스템 설정을 변경하기 때문에 root 권한이 필요합니다:
- `/run/current-system` 심볼릭 링크 생성
- `/etc/nix/nix.conf` 수정
- launchd/systemd 서비스 등록

### SSH 키 invalid format

**에러 메시지**:
```
Load key "/Users/username/.ssh/id_ed25519": invalid format
git@github.com: Permission denied (publickey).
```

**원인**: SSH 키 파일이 손상되었거나, 복사/붙여넣기 과정에서 형식이 깨졌습니다. 일반적인 원인:
1. 파일 끝에 빈 줄(newline)이 없음
2. 줄 끝에 불필요한 공백이 있음
3. 줄바꿈 문자가 잘못됨 (Windows CRLF vs Unix LF)

**해결**:

1. **파일 끝에 빈 줄 추가**:
   ```bash
   echo "" >> ~/.ssh/id_ed25519
   ```

2. **줄 끝 공백 제거**:
   ```bash
   sed -i '' 's/[[:space:]]*$//' ~/.ssh/id_ed25519
   ```

3. **원본 파일 다시 복사** (권장):
   - USB, AirDrop, scp 등으로 **파일 자체**를 복사
   - 텍스트 복사/붙여넣기 대신 바이너리 복사 사용

**검증**:
```bash
# SSH 키 유효성 검사
ssh-keygen -y -f ~/.ssh/id_ed25519
# 공개키가 출력되면 정상

# GitHub 연결 테스트
ssh -T git@github.com
```

---

## NixOS SSH 관련

### SSH 키 등록 시 fingerprint 불일치 (O vs 0 오타)

> **발생 시점**: 2026-01-17 (MiniPC NixOS 설치)

**증상**: SSH 키를 GitHub에 등록했는데 `Permission denied (publickey)` 에러.

```bash
$ ssh -T git@github.com
git@github.com: Permission denied (publickey).
```

**원인**: SSH 공개키를 수동으로 복사할 때 `O`(대문자 O)와 `0`(숫자 0)을 혼동.

```
# MiniPC의 실제 키
ssh-ed25519 AAAAC3Nza...I806sMRc...  # "I806" (숫자 0)

# GitHub에 잘못 등록된 키
ssh-ed25519 AAAAC3Nza...I8O6sMRc...  # "I8O6" (대문자 O)
```

**진단**: fingerprint 비교

```bash
# 로컬 키의 fingerprint
$ ssh-keygen -lf ~/.ssh/id_ed25519.pub
SHA256:rQkj8SQoIe7nFdTrnGfK1+poZquyienxBL6FF5/Ut1k

# GitHub에 등록된 키의 fingerprint (GitHub 설정 페이지에서 확인)
SHA256:aUP+sMvwSClsQoLxP7P30vxpQi7Xe/GGjeB0L0PF/Zc  # 다름!
```

**해결**:

1. GitHub에서 잘못된 키 삭제
2. 터미널에서 `cat ~/.ssh/id_ed25519.pub` 출력
3. **전체를 정확히 복사**하여 GitHub에 재등록

**예방**:

- 터미널 폰트가 `O`와 `0`을 명확히 구분하는지 확인
- 가능하면 `ssh-copy-id`나 클립보드 복사 사용
- 등록 후 `ssh -T git@github.com`으로 즉시 테스트

---

### Mac에서 MiniPC SSH 접속 실패 (Tailscale 만료)

> **발생 시점**: 2026-01-17 (MiniPC NixOS 설치)

**증상**: Mac에서 MiniPC로 SSH 접속 시 타임아웃.

```bash
$ ssh greenhead@100.79.80.95
ssh: connect to host 100.79.80.95 port 22: Operation timed out
```

**원인**: Mac의 Tailscale 세션이 만료됨.

Tailscale 관리 콘솔에서 확인:
```
macbookpro    100.126.197.36    Expired Sep 18, 2025
greenhead-minipc    100.79.80.95    Connected
```

**해결**: Mac에서 Tailscale 재인증

```bash
# macOS GUI
# 메뉴바 Tailscale 아이콘 → Log in

# 또는 CLI (설치된 경우)
$ tailscale up
```

**확인**:

```bash
$ tailscale status
100.65.50.98  greenhead-macbookpro  user@  macOS  -
100.79.80.95  greenhead-minipc      user@  linux  active; direct ...

# SSH 재시도
$ ssh greenhead@100.79.80.95
greenhead@greenhead-minipc:~$  # 성공!
```

**예방**: Tailscale 키 만료 전에 갱신하거나, 자동 갱신 설정 확인.

---

### sudo에서 SSH 키 인증 실패 (SSH_AUTH_SOCK)

> **발생 시점**: 2026-01-18 (MiniPC NixOS 설정)

**증상**: SSH 키가 ssh-agent에 로드되어 있고 `ssh -T git@github.com`은 성공하지만, `sudo` 명령에서 SSH 인증 실패.

```bash
$ ssh -T git@github.com
Hi shren207! You've successfully authenticated...

$ sudo git clone git@github.com:user/repo
git@github.com: Permission denied (publickey).
```

**원인**: `sudo`는 root 사용자로 명령을 실행하므로, 현재 사용자의 `SSH_AUTH_SOCK` 환경변수를 상속받지 않습니다.

```
일반 사용자 → ssh-agent (SSH_AUTH_SOCK 설정됨)
     ↓
   sudo → root 사용자 (SSH_AUTH_SOCK 없음) → SSH 키 접근 불가
```

**해결**: `SSH_AUTH_SOCK` 환경변수를 sudo에 전달

```bash
sudo SSH_AUTH_SOCK=$SSH_AUTH_SOCK <command>
```

**대안**: sudoers에서 환경변수 유지 설정 (NixOS)

```nix
# configuration.nix
security.sudo.extraConfig = ''
  Defaults env_keep += "SSH_AUTH_SOCK"
'';
```

---

### SSH에서 sudo 비밀번호 입력 불가

> **발생 시점**: 2026-01-18 (MiniPC NixOS 설정)

**증상**: Mac에서 SSH로 MiniPC에 접속 후 sudo 명령 실행 시 비밀번호 입력 불가.

```bash
$ ssh minipc "sudo nixos-rebuild switch --flake .#greenhead-minipc"
sudo: a terminal is required to read the password; either use ssh's -t option or configure an askpass helper
```

**원인**: 비인터랙티브 SSH 세션에서는 sudo가 비밀번호를 입력받을 TTY가 없습니다.

**해결**: NixOS에서 wheel 그룹에 NOPASSWD 설정

```nix
# modules/nixos/configuration.nix
security.sudo.wheelNeedsPassword = false;
```

**보안 고려사항**:

| 우려 | 실제 상황 |
|------|-----------|
| 설정이 public repo에 노출됨 | 정책 설정일 뿐, 민감 정보 아님 |
| 누구나 sudo 가능? | Tailscale + SSH 키 인증 필요 |
| 비밀번호 없이 위험하지 않나? | 이미 SSH 키로 인증됨, 추가 비밀번호는 중복 |

**보안 레이어 구조**:
```
외부 인터넷
     ↓ (Tailscale VPN 필요)
Tailscale 네트워크
     ↓ (SSH 키 인증 필요)
MiniPC SSH 접속
     ↓ (NOPASSWD)
sudo 실행
```

공격자가 sudo 설정을 알아도 Tailscale 네트워크 접근 + SSH 개인키가 없으면 무의미합니다.

**참고**: 많은 NixOS 사용자들이 public dotfiles에 이 설정을 사용합니다.

---

### Tailscale MagicDNS에서 외부 도메인 해석 실패 (SERVFAIL)

> **발생 시점**: 2026-02-13
> **원인**: Tailscale 1.94.0→1.94.1 업데이트 후 시스템 DNS fallback 경로 변경

**증상**: MiniPC에서 Claude Code 등 인터넷 연결이 필요한 도구가 작동하지 않음. `ping 1.1.1.1`은 성공하지만 도메인 해석 실패.

```bash
$ ping google.com
ping: google.com: Name or service not known

$ host google.com 100.100.100.100
Host google.com not found: 2(SERVFAIL)
```

**진단**:

```bash
# DNS만 실패하는지 확인
$ ping -c 1 1.1.1.1        # 성공 → 인터넷 연결 자체는 정상
$ ping -c 1 google.com      # 실패 → DNS 문제

# resolv.conf 확인
$ cat /etc/resolv.conf
nameserver 100.100.100.100   # ← Tailscale MagicDNS만 설정됨

# Tailscale DNS 상태 확인
$ tailscale dns status
# Resolvers: (no resolvers configured)
# System DNS: (failed to read system DNS configuration: Access denied)

# tailscaled 로그에서 SERVFAIL 확인
$ journalctl -u tailscaled | grep 'no upstream resolvers'
```

**원인 분석**:

| 항목 | 설명 |
|------|------|
| `DefaultResolvers:[]` | Tailscale admin console에 global nameserver 미설정 (원래부터) |
| 이전에 작동한 이유 | Tailscale이 시스템 DNS(DHCP 등)로 fallback |
| 현재 실패 이유 | 1.94.1에서 `dns-osconfig dump access denied` → 시스템 DNS 읽기 불가 |

Tailscale 버전 업데이트(1.94.0→1.94.1)로 NixOS 환경에서 시스템 DNS fallback 메커니즘이 변경되어, 원래 잠재되어 있던 미설정 문제가 표면화됨.

**해결**: Tailscale admin console (https://login.tailscale.com/admin/dns)에서:

1. **Global nameservers**에 공용 DNS 추가:
   - Google Public DNS: `8.8.8.8` (+ `8.8.4.4`, IPv6)
   - Cloudflare Public DNS: `1.1.1.1` (+ `1.0.0.1`, IPv6)
2. **Override DNS servers** 활성화

**보안 참고**: "Override DNS servers"는 Tailscale이 admin에서 설정한 DNS를 로컬 네트워크 DNS보다 우선 사용하는 설정. 오히려 악의적 로컬 DNS 하이재킹을 방지하므로 보안상 유리.

**적용 확인**:

```bash
# DNS 즉시 복구 확인 (tailscaled 재시작 불필요)
$ host google.com
google.com has address 142.250.194.14

# tailscaled 로그에서 resolver 반영 확인
$ journalctl -u tailscaled --since '5 min ago' | grep DefaultResolvers
# DefaultResolvers:[8.8.8.8 8.8.4.4 ... 1.1.1.1 1.0.0.1 ...]

# Claude Code 동작 확인
$ claude -p 'say hello'
```

**교훈**: Tailscale MagicDNS를 사용할 때는 반드시 admin console에서 global nameserver를 명시적으로 설정할 것. 시스템 DNS fallback에 의존하면 Tailscale 버전 업데이트 시 예고 없이 깨질 수 있음.

---

### Ghostty SSH 접속 시 unknown terminal type

> **발생 시점**: 2026-01-18 (MiniPC NixOS 설정)

**증상**: Ghostty 터미널에서 SSH로 MiniPC 접속 시 터미널 타입 에러 및 레이아웃 깨짐.

```bash
$ ssh minipc
$ clear
'xterm-ghostty': unknown terminal type.
```

터미널 레이아웃, 커서 위치가 모두 깨지는 현상 발생.

**원인**: MiniPC (NixOS)에 Ghostty의 terminfo가 설치되지 않음.

| Mac (Ghostty) | MiniPC (NixOS) |
|---------------|----------------|
| TERM=xterm-ghostty 전송 | terminfo 없음 → 에러 |

**해결 1 (임시)**: SSH 접속 시 TERM 변경

```bash
TERM=xterm-256color ssh minipc
```

**해결 2 (영구)**: MiniPC에 ghostty 패키지 설치

```nix
# modules/nixos/home.nix
home.packages = with pkgs; [
  ghostty  # terminfo 포함
  # ...
];
```

```bash
$ sudo nixos-rebuild switch --flake .#greenhead-minipc
# ghostty-1.2.3 설치됨 (terminfo 포함)
```

**확인**:

```bash
$ ssh minipc
$ clear
# 정상 작동, 레이아웃 깨지지 않음
$ infocmp xterm-ghostty
# terminfo 정보 출력됨
```

**참고**: Ghostty는 GUI 앱이지만 terminfo만 필요한 경우에도 전체 패키지를 설치해야 합니다. 서버에서 GUI는 사용하지 않지만 terminfo는 SSH 접속에 필요합니다.
