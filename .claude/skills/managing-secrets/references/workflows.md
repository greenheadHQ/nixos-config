# Secret 워크플로 상세

## 명령 준비

명령을 실행할 호스트의 저장소 루트에서 devShell에 진입한다. devShell의 agenix는 이 checkout의 `flake.lock`에 고정된 input에서 제공한다. devShell이 PATH 앞에 제공하는 외부 CLI를 alias·함수와 셸 초기화 파일의 영향을 받지 않는 Bash에서 찾는다. 절대 실행경로·실행 권한을 확인하고, 확인에 실패하면 그 자리에서 종료한다. 확인한 뒤 `secrets/`로 이동한다.

```bash
cd <repo-root>
nix develop
if ! agenix_bin="$(command env -u BASH_ENV bash --noprofile --norc -p -c 'builtin type -P agenix')" ||
   [ "${agenix_bin#/}" = "$agenix_bin" ] || [ ! -x "$agenix_bin" ]; then
  printf '%s\n' 'devShell agenix 실행 파일을 찾지 못했습니다.' >&2
  exit 1
fi
cd secrets
```

아래 명령은 이 devShell의 `secrets/`에서 일반·sudo 모두 확인한 `"$agenix_bin"`을 실행한다. 매번 `AGENIX_RULES="$PWD/secrets.nix"`로 기존 규칙 파일을 지정하므로 자동 탐색에 의존하지 않는다. 다른 호스트의 checkout에서도 먼저 같은 준비를 한다.

## .age 파일 생성/암호화

사람이 대화형 터미널에서 `agenix -e`로 값을 입력한다. 에이전트는 선언·명령·경로를 준비한다.

```bash
AGENIX_RULES="$PWD/secrets.nix" "$agenix_bin" -e <name>.age
# 에디터에서 내용 입력 후 저장 → 자동 암호화
```

추가와 수정 모두 동일한 명령으로 처리.

`agenix -e`를 사용할 수 없으면 [troubleshooting.md](troubleshooting.md)의 "agenix -e의 /dev/stdin 에러" 절차를 따른다. 보호된 임시 파일에 사람이 입력하고 암호화·왕복 검증 후 교체하는 정본이다. 에이전트는 코드 블록과 `<name>`·공개키 치환값·저장소 루트 경로를 준비해 사람에게 전달하며, 값 입력은 사람이 대화형 터미널에서 한다.

우회 절차의 recipient는 `secrets/secrets.nix`에서 그 항목의 `publicKeys`에 있는 공개키마다 `-r` 인수를 하나씩 지정한다. 참조 명령의 `-r` 인수도 공개키 수에 맞춰 추가하거나 삭제한다. 항목마다 recipient 그룹이 다르므로 다른 항목의 목록을 옮겨 쓰지 않는다.

## 기존 secret 상태 확인 (값 비출력)

- 복호화 가능 여부: [troubleshooting.md](troubleshooting.md)의 "복호화 실패" 절에 있는 `>/dev/null` 진단으로 성공 여부만 확인한다.
- 배포된 파일의 존재·필수 키 유무: 같은 문서의 "배포 후 검증" 코드 블록으로 확인한다. `grep -q '^KEY='`는 `KEY=value` 형식에만 쓰며, 배포 경로는 `age.secrets.<name>.path`를 따른다.
- 내용 열람·수정: 사람이 대화형 터미널에서 위 `agenix -e` 명령으로 에디터를 연다. 에이전트에는 값 대신 확인 결과만 전달한다.

## 호스트 추가

새 호스트가 일부 secret을 복호화해야 할 때의 절차다. 확인·재암호화 명령은 재암호화할 호스트의 저장소 checkout에서, 갱신한 `libraries/constants.nix`·`secrets/secrets.nix`가 반영된 상태로 위 "명령 준비"를 수행한 뒤 실행한다. `AGENIX_RULES`가 가리키는 `secrets/secrets.nix`를 기준으로 대상 파일 경로를 해석한다.

recipient 그룹마다 복호화에 필요한 identity가 다르다. 그룹 선언은 `secrets/secrets.nix`에, 항목별 그룹은 [SKILL.md](../SKILL.md) 통합 Secret Inventory의 recipient 열에 있다.

| 그룹 | 담긴 공개키 | 복호화 identity |
|------|-------------|-----------------|
| `allHosts` | Mac·MiniPC 사용자 키 (`sshKeys`) | Mac 또는 MiniPC 사용자의 `~/.ssh/id_ed25519` |
| `minipcOnly` | MiniPC 사용자 키 (`sshKeys.minipc`) | MiniPC 사용자의 `~/.ssh/id_ed25519` |
| `minipcHostOnly` | MiniPC 호스트 키 (`hostKeys.minipc`) | MiniPC의 `/etc/ssh/ssh_host_ed25519_key` (root만 읽을 수 있어 5~8단계를 sudo로 실행한다) |
| `[ constants.sshKeys.macbook ]` (인라인) | Mac 사용자 키 | Mac 사용자의 `~/.ssh/id_ed25519` |

1. 호스트 등록: `scripts/add-host.sh`의 안내대로 새 호스트의 사용자 공개키를 `libraries/constants.nix`의 `sshKeys`에 등록한다. 호스트 키 전용 항목이 필요하면 그 호스트의 `/etc/ssh/ssh_host_ed25519_key.pub`를 `hostKeys`에 따로 등록한다. NixOS 호스트 한정이다 — darwin은 Home Manager agenix가 사용자 키로만 복호화한다.
2. 필요한 시크릿 식별: 새 호스트가 실제로 소비하는 항목만 고른다. 배포 선언은 Home Manager 시크릿이 `modules/shared/programs/secrets/default.nix`에, NixOS 서비스 시크릿이 각 서비스 모듈에 있다.
3. `publicKeys` 확인: `secrets/secrets.nix`에서 고른 항목마다 어느 그룹이나 인라인 목록을 쓰는지 본다. 그룹을 고치면 그 그룹을 쓰는 모든 항목의 recipient가 함께 바뀐다.
4. 필요한 recipient만 추가: 고른 항목에 필요한 키만 넣는다. 같은 그룹의 다른 항목까지 열 필요가 없으면 인라인 목록이나 새 그룹을 쓴다. 모든 항목을 공통 그룹으로 모으지 않는다.
5. identity 확인과 바이트 수 기록: 재암호화할 호스트에서, 넘길 identity로 대상 항목을 복호화할 수 있는지 확인하고 재암호화 전 바이트 수를 적어 둔다. 원문은 버린다. 값은 출력하지 않고 해시로도 비교하지 않는다 — 짧은 값은 해시로 역산할 수 있다. 빈 값 placeholder로 둔 항목(`secrets.nix` 주석 참조)은 0일 수 있다.

   ```bash
   test -f <name>.age && AGENIX_RULES="$PWD/secrets.nix" "$agenix_bin" -d <name>.age -i <identity> >/dev/null && AGENIX_RULES="$PWD/secrets.nix" "$agenix_bin" -d <name>.age -i <identity> | wc -c
   test -f <name>.age && sudo AGENIX_RULES="$PWD/secrets.nix" "$agenix_bin" -d <name>.age -i /etc/ssh/ssh_host_ed25519_key >/dev/null && sudo AGENIX_RULES="$PWD/secrets.nix" "$agenix_bin" -d <name>.age -i /etc/ssh/ssh_host_ed25519_key | wc -c  # 호스트 키
   ```

   바이트 수가 출력되지 않으면 파일이 없거나 복호화에 실패한 것이다. 선언만 있고 파일이 없는 항목은 `-d`가 빈 출력과 rc 0으로 끝나고, `-d` 출력을 `wc -c`로 세는 파이프는 복호화가 실패해도 `0`과 rc 0을 내므로 `test -f`와 복호화 성공 확인(`>/dev/null &&`)을 앞에 둔다.

6. 재암호화: 확인된 항목만 재암호화한다. `EDITOR=:`이면 agenix가 에디터를 열지 않고, 복호화한 내용을 현재 `publicKeys`로 다시 암호화한다. `-r`이 항목마다 쓰는 경로와 같다. `EDITOR=:`가 agenix까지 전달되지 않으면 비대화형 실행에서 표준입력이 값을 대체해 시크릿이 비워진다(rc는 0이다). sudo는 앞에 둔 환경 변수를 명령에 넘기지 않으므로, 호스트 키 항목은 `AGENIX_RULES`와 `EDITOR=:`를 sudo 뒤에 두고 devShell에서 기록한 절대 CLI 경로를 쓴다.

   ```bash
   AGENIX_RULES="$PWD/secrets.nix" EDITOR=: "$agenix_bin" -e <name>.age -i <identity>
   # 호스트 키 전용 항목 (root). 새 파일이 root 소유가 되므로 소유자를 되돌린다.
   sudo AGENIX_RULES="$PWD/secrets.nix" EDITOR=: "$agenix_bin" -e <name>.age -i /etc/ssh/ssh_host_ed25519_key
   sudo chown "$USER" <name>.age
   ```

7. 값 보존 확인: 재암호화한 항목을 복호화해 바이트 수가 재암호화 전과 같은지 본다(5단계에서 적어 둔 값). 다르면 `git restore <name>.age`로 되돌린다.

   ```bash
   test -f <name>.age && AGENIX_RULES="$PWD/secrets.nix" "$agenix_bin" -d <name>.age -i <identity> >/dev/null && AGENIX_RULES="$PWD/secrets.nix" "$agenix_bin" -d <name>.age -i <identity> | wc -c
   test -f <name>.age && sudo AGENIX_RULES="$PWD/secrets.nix" "$agenix_bin" -d <name>.age -i /etc/ssh/ssh_host_ed25519_key >/dev/null && sudo AGENIX_RULES="$PWD/secrets.nix" "$agenix_bin" -d <name>.age -i /etc/ssh/ssh_host_ed25519_key | wc -c  # 호스트 키
   ```

   바이트 수가 출력되지 않으면 복호화에 실패한 것이다(값 비교 전에 멈춘다).

8. 새 호스트 확인: 변경을 커밋·push하고 새 호스트에서 pull한 뒤, 새 호스트의 identity로 재암호화한 항목을 복호화해 바이트 수가 5단계에서 적어 둔 값과 같은지 본다. 5~7단계는 기존 identity로만 복호화하므로, 형식은 맞지만 다른 공개키를 등록해도 모두 통과한다. 이 확인이 끝나기 전에는 recipient 갱신을 완료로 보지 않는다.

   ```bash
   # 새 호스트의 저장소 checkout에서도 "명령 준비" 후 secrets/에서
   test -f <name>.age && AGENIX_RULES="$PWD/secrets.nix" "$agenix_bin" -d <name>.age -i ~/.ssh/id_ed25519 >/dev/null && AGENIX_RULES="$PWD/secrets.nix" "$agenix_bin" -d <name>.age -i ~/.ssh/id_ed25519 | wc -c
   test -f <name>.age && sudo AGENIX_RULES="$PWD/secrets.nix" "$agenix_bin" -d <name>.age -i /etc/ssh/ssh_host_ed25519_key >/dev/null && sudo AGENIX_RULES="$PWD/secrets.nix" "$agenix_bin" -d <name>.age -i /etc/ssh/ssh_host_ed25519_key | wc -c  # 호스트 키
   ```

   바이트 수가 출력되지 않으면 복호화에 실패한 것이다(값 비교 전에 멈춘다). 복호화에 실패하거나 바이트 수가 다르면 등록한 공개키가 그 호스트의 실제 키와 다르다. 새 호스트에서 `ssh-keygen -y -f ~/.ssh/id_ed25519` 출력(호스트 키는 `/etc/ssh/ssh_host_ed25519_key.pub`)을 `libraries/constants.nix` 값과 비교해 고친 뒤 5~8단계를 다시 한다.

전체 재암호화(`AGENIX_RULES="$PWD/secrets.nix" "$agenix_bin" -r`)는 넘긴 identity로 `secrets.nix`의 모든 항목을 복호화할 수 있을 때만 쓴다. `-r`은 항목을 차례로 처리하다 복호화하지 못하는 항목에서 멈추고, 그 앞 항목만 새 recipient로 바뀐 채 남는다. 현재 선언에는 Mac 사용자 키 전용 항목과 MiniPC 호스트 키 전용 항목이 함께 있어, 한 호스트의 identity만으로는 이 조건을 채우지 못한다. identity가 없는 항목은 그 identity가 있는 호스트에서 대상별로 재암호화한다. 원본 값에서 새로 암호화해야 하면 [troubleshooting.md](troubleshooting.md)의 "agenix -e의 /dev/stdin 에러" 절차를 쓴다.
