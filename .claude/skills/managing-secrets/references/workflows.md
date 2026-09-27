# Secret 워크플로 상세

## .age 파일 생성/암호화

Interactive (터미널) -- `agenix -e` 사용:

```bash
cd secrets && nix run github:ryantm/agenix -- -e <name>.age
# 에디터에서 내용 입력 후 저장 → 자동 암호화
```

추가와 수정 모두 동일한 명령으로 처리.

Non-interactive (Claude Code) -- `age` CLI pipe 사용:

```bash
# 1. secrets/secrets.nix에서 공개키 확인
# 2. 모든 recipient에 대해 -r 플래그 지정
nix shell nixpkgs#age -c sh -c 'printf "KEY=value\n" | age \
  -r "ssh-ed25519 <key1>" \
  -r "ssh-ed25519 <key2>" \
  -o secrets/<name>.age'
```

`secrets/secrets.nix`에서 그 항목의 `publicKeys`에 있는 공개키를 모두 `-r` 플래그로 지정한다. 항목마다 recipient 그룹이 다르므로 다른 항목의 목록을 옮겨 쓰지 않는다.

## 기존 secret 내용 확인 (복호화)

```bash
nix shell nixpkgs#age -c age -d -i ~/.ssh/id_ed25519 secrets/<name>.age
```

## 호스트 추가

새 호스트가 일부 secret을 복호화해야 할 때의 절차다. 확인·재암호화 명령은 재암호화할 호스트의 저장소 checkout에서, 갱신한 `libraries/constants.nix`·`secrets/secrets.nix`가 반영된 상태로 `secrets/`에서 실행한다. agenix는 현재 디렉토리의 규칙 파일 `secrets.nix`를 읽으므로 저장소 루트에서는 규칙 파일을 찾지 못한다.

recipient 그룹마다 복호화에 필요한 identity가 다르다. 그룹 선언은 `secrets/secrets.nix`에, 항목별 그룹은 [SKILL.md](../SKILL.md) 통합 Secret Inventory의 recipient 열에 있다.

| 그룹 | 담긴 공개키 | 복호화 identity |
|------|-------------|-----------------|
| `allHosts` | Mac·MiniPC 사용자 키 (`sshKeys`) | Mac 또는 MiniPC 사용자의 `~/.ssh/id_ed25519` |
| `minipcOnly` | MiniPC 사용자 키 (`sshKeys.minipc`) | MiniPC 사용자의 `~/.ssh/id_ed25519` |
| `minipcHostOnly` | MiniPC 호스트 키 (`hostKeys.minipc`) | MiniPC의 `/etc/ssh/ssh_host_ed25519_key` (root만 읽을 수 있어 5~7단계를 sudo로 실행한다) |
| `[ constants.sshKeys.macbook ]` (인라인) | Mac 사용자 키 | Mac 사용자의 `~/.ssh/id_ed25519` |

1. 호스트 등록: `scripts/add-host.sh`의 안내대로 새 호스트의 사용자 공개키를 `libraries/constants.nix`의 `sshKeys`에 등록한다. 호스트 키 전용 항목이 필요하면 그 호스트의 `/etc/ssh/ssh_host_ed25519_key.pub`를 `hostKeys`에 따로 등록한다. NixOS 호스트 한정이다 — darwin은 Home Manager agenix가 사용자 키로만 복호화한다.
2. 필요한 시크릿 식별: 새 호스트가 실제로 소비하는 항목만 고른다. 배포 선언은 Home Manager 시크릿이 `modules/shared/programs/secrets/default.nix`에, NixOS 서비스 시크릿이 각 서비스 모듈에 있다.
3. `publicKeys` 확인: `secrets/secrets.nix`에서 고른 항목마다 어느 그룹이나 인라인 목록을 쓰는지 본다. 그룹을 고치면 그 그룹을 쓰는 모든 항목의 recipient가 함께 바뀐다.
4. 필요한 recipient만 추가: 고른 항목에 필요한 키만 넣는다. 같은 그룹의 다른 항목까지 열 필요가 없으면 인라인 목록이나 새 그룹을 쓴다. 모든 항목을 공통 그룹으로 모으지 않는다.
5. identity 확인: 재암호화할 호스트에서, 넘길 identity로 대상 항목을 복호화할 수 있는지 먼저 확인한다. 원문은 버린다. 선언만 있고 파일이 없는 항목은 `-d`가 빈 출력과 rc 0으로 끝나므로 `test -f`를 앞에 둔다.

   ```bash
   cd secrets
   test -f <name>.age && nix run github:ryantm/agenix -- -d <name>.age -i <identity> >/dev/null && echo "복호화 가능"
   test -f <name>.age && sudo nix run github:ryantm/agenix -- -d <name>.age -i /etc/ssh/ssh_host_ed25519_key >/dev/null && echo "복호화 가능"  # 호스트 키
   ```

   재암호화 전 바이트 수를 적어 둔다. 빈 값 placeholder로 둔 항목(`secrets.nix` 주석 참조)은 0일 수 있다. 값은 출력하지 않고 해시로도 비교하지 않는다 — 짧은 값은 해시로 역산할 수 있다.

   ```bash
   nix run github:ryantm/agenix -- -d <name>.age -i <identity> | wc -c
   sudo nix run github:ryantm/agenix -- -d <name>.age -i /etc/ssh/ssh_host_ed25519_key | wc -c  # 호스트 키
   ```

6. 재암호화: 확인된 항목만 재암호화한다. `EDITOR=:`이면 agenix가 에디터를 열지 않고, 복호화한 내용을 현재 `publicKeys`로 다시 암호화한다. `-r`이 항목마다 쓰는 경로와 같다. `EDITOR=:`가 agenix까지 전달되지 않으면 비대화형 실행에서 표준입력이 값을 대체해 시크릿이 비워진다(rc는 0이다). sudo는 앞에 둔 환경 변수를 명령에 넘기지 않으므로, 호스트 키 항목은 `EDITOR=:`를 sudo 뒤에 둔다.

   ```bash
   EDITOR=: nix run github:ryantm/agenix -- -e <name>.age -i <identity>
   # 호스트 키 전용 항목 (root). 새 파일이 root 소유가 되므로 소유자를 되돌린다.
   sudo EDITOR=: nix run github:ryantm/agenix -- -e <name>.age -i /etc/ssh/ssh_host_ed25519_key
   sudo chown "$USER" <name>.age
   ```

7. 값 보존 확인: 재암호화한 항목을 복호화해 바이트 수가 재암호화 전과 같은지 본다(5단계에서 적어 둔 값). 다르면 `git restore <name>.age`로 되돌린다.

   ```bash
   nix run github:ryantm/agenix -- -d <name>.age -i <identity> | wc -c
   sudo nix run github:ryantm/agenix -- -d <name>.age -i /etc/ssh/ssh_host_ed25519_key | wc -c  # 호스트 키
   ```

전체 재암호화(`nix run github:ryantm/agenix -- -r`)는 넘긴 identity로 `secrets.nix`의 모든 항목을 복호화할 수 있을 때만 쓴다. `-r`은 항목을 차례로 처리하다 복호화하지 못하는 항목에서 멈추고, 그 앞 항목만 새 recipient로 바뀐 채 남는다. 현재 선언에는 Mac 사용자 키 전용 항목과 MiniPC 호스트 키 전용 항목이 함께 있어, 한 호스트의 identity만으로는 이 조건을 채우지 못한다. identity가 없는 항목은 그 identity가 있는 호스트에서 대상별로 재암호화한다. 원본 값에서 새로 암호화해야 하면 [troubleshooting.md](troubleshooting.md)의 "agenix -e의 /dev/stdin 에러" 절차를 쓴다.
