# 트러블슈팅

아래 `age` 명령은 `nix-shell -p age` 환경에서 실행 (devShell에 미포함).
1Password 함정(op read 비대화형 hang / SA 만료일 GUI 전용 / agent.toml 승인 팝업)은 [1password.md](1password.md)의 트러블슈팅 참조.

## agenix -e의 /dev/stdin 에러

> 발생 시점: 2026-01-27
> 해결: age CLI pipe 우회

증상: Claude Code Bash 환경에서 `agenix -e` 실행 시 실패.

```
cp: cannot open '/dev/stdin' for reading: No such device or address
pushover-claude-stop.age wasn't created.
```

`EDITOR="cp $TMPFILE"` 스크립트 우회도 동일하게 실패.

원인: `agenix -e`는 내부적으로 `/dev/stdin`을 사용하는 interactive 모델이다. Claude Code의 Bash 환경은 non-interactive라 `/dev/stdin`이 없다.

| 방식 | 대화형 터미널(사람) | 에이전트(non-interactive) |
|------|:--:|:--:|
| `agenix -e` | O | X (`/dev/stdin` 없음) |
| 아래 절차 | O (사람이 값을 입력) | X (값을 다루지 않는다) |

이 절차는 값을 사람이 대화형 터미널에서 입력하는 경로다. 에이전트는 값을 대신 입력하지 않는다 — `cat > file`이 표준입력이 아닌 곳(파이프, `/dev/null`, 에이전트 Bash 도구 등)에서 실행되면 즉시 EOF를 만나 빈 파일이 되고, 그 빈 값이 그대로 암호화되어 기존 `.age` 파일을 빈 값으로 덮어쓸 수 있다. 아래 절차는 첫 줄에서 대화형 터미널 여부를 확인해 이 경로를 막는다. 사람에게 값 입력을 넘기는 방법(예: Claude Code의 `!` 접두 명령이 TTY 표준입력을 주는지)은 확인되지 않았으면 단정하지 말고 "사용자 터미널에서 실행"으로 안내한다.

해결: `age` CLI를 직접 호출하되, 임시 파일 경유로 암호화한다. 값은 명령 텍스트에 직접 적지 않는다 — xtrace, 셸 히스토리(Atuin 동기화 대상), 에이전트 대화 기록에 그대로 남기 때문이다. 아래처럼 서브셸로 감싸 임시 디렉터리를 격리하고, 값은 `cat >`으로 붙여넣은 뒤 Ctrl-D(EOF)로 받는다. 최상위(대화형 셸)에 `trap`을 걸면 그 셸이 끝날 때까지 발동하지 않아, 같은 셸에서 두 번 반복하면 첫 임시 디렉터리가 영구히 남는다 — 서브셸 `( … )`로 감싸야 서브셸 종료 시점에 즉시 정리된다. 정리 중에는 EXIT trap 자체를 시그널로 중단당하지 않도록 신호를 무시하고, HUP·QUIT도 함께 잡는다.

새 암호문은 기존 `secrets/<name>.age`를 바로 덮어쓰지 않고 임시 경로에 먼저 쓴 뒤, 왕복 검증(암호화한 내용을 즉시 복호화해 입력 평문과 비교)을 통과했을 때만 옮긴다. 왕복 복호화가 실패하면 "값 손상"과 "이 호스트가 애초에 이 시크릿의 recipient가 아님"(다른 호스트 전용 시크릿을 여기서 암호화하는 정상적인 경우)을 구분해야 한다 — 후자는 손상 여부를 이 호스트에서 확인할 수 없을 뿐이므로 경고만 하고 교체를 막지 않는다(recipient는 `secrets/secrets.nix`에서 관리). 값 입력이 끝난 뒤 `nrs` 배포와 그 결과 확인은 붙여넣기 경계가 다른 별도 코드 블록이다 — bracketed paste를 지원하지 않는 터미널에서 한 번에 이어 붙이면 뒷부분이 입력값에 섞여 그대로 암호화될 수 있다.

```bash
[ -t 0 ] || { echo "값 입력은 사용자가 대화형 터미널에서 한다 — 이 셸의 표준입력은 대화형이 아니다." >&2; exit 1; }

(
  umask 077
  d=$(mktemp -d) || exit 1
  trap 'trap "" HUP INT TERM QUIT; rm -rf "$d"' EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 131' QUIT
  trap 'exit 143' TERM

  # 값을 붙여넣고 Ctrl-D(EOF)로 종료 — 예: KEY=<실제 값>
  cat > "$d/secret"
  chmod 0600 "$d/secret"
  [ -s "$d/secret" ] || { echo "입력이 비어 있다 — 아무것도 쓰지 않고 중단한다." >&2; exit 1; }

  nix-shell -p age --run \
    "age -r 'ssh-ed25519 <key1>' -r 'ssh-ed25519 <key2>' -o '$d/out.age' '$d/secret'"

  # 왕복 검증 (원문은 출력하지 않음). 종료 코드로 "이 호스트 키로 복호화 불가"와
  # "복호화는 됐지만 값이 다름"을 구분한다.
  nix-shell -p age --run \
    "age -d -i ~/.ssh/id_ed25519 '$d/out.age'" > "$d/roundtrip" 2>"$d/decrypt.err"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "왕복 검증: 이 호스트 키로는 복호화할 수 없음 — secrets/secrets.nix의 recipient 목록을 확인한다(다른 호스트 전용 시크릿이면 정상, 이 호스트에서는 손상 여부를 확인할 수 없다)." >&2
  elif cmp -s "$d/secret" "$d/roundtrip"; then
    echo "왕복 검증: 일치"
  else
    echo "왕복 검증: 불일치 — 값이 손상됐다. 배치를 중단한다."
    exit 1
  fi
  [ "$rc" -eq 0 ] && { grep -qF '\' "$d/roundtrip" && echo "백슬래시 포함: 있음" || echo "백슬래시 포함: 없음"; }

  mv "$d/out.age" secrets/<name>.age
  echo "secrets/<name>.age 교체 완료"
)
```

--- 이 아래는 별도 붙여넣기(다른 코드 블록)로 실행한다. `nrs`로 배포한 뒤 확인한다 ---

```bash
# 배포 후 검증 (원문은 출력하지 않음) — 존재/비어있지 않음, 필수 키 유무만 확인.
# 아래 grep '^KEY='는 KEY=value 형식(env) 시크릿 예시에 한정된다. 배포 경로는 시크릿마다
# age.secrets.<name>.path 기준이며, Home Manager로 배포되는 시크릿은 /run/agenix가 아니다.
sudo test -s /run/agenix/<name> && echo "배포됨/비어있지 않음" || echo "미배포/비어있음"
sudo grep -q '^KEY=' /run/agenix/<name> && echo "KEY 있음" || echo "KEY 없음"
```

---

## 복호화 실패

증상: `age -d`로 복호화 시 에러.

```
Error: no identity matched any of the recipients
```

원인:

1. SSH 키 불일치: 현재 머신의 SSH 키가 암호화 시 recipient에 포함되지 않음
2. identity path 오류: 기본 경로(`~/.ssh/id_ed25519`)가 아닌 경우

진단:

```bash
# 현재 머신의 공개키 확인
cat ~/.ssh/id_ed25519.pub

# secrets/secrets.nix의 allHosts에 포함되어 있는지 확인
```

해결: identity path를 명시적으로 지정해 복호화가 성공하는지 확인 (원문은 출력하지 않음).

```bash
nix-shell -p age --run 'age -d -i ~/.ssh/id_ed25519 secrets/<name>.age' >/dev/null \
  && echo "복호화 성공" || echo "복호화 실패"
```

키가 포함되어 있지 않다면 `secrets/secrets.nix`에 공개키 추가 후 `cd secrets && nix run github:ryantm/agenix -- -r`로 재암호화 필요.

---

## 재암호화 실패

증상: `secrets/secrets.nix`에서 publicKeys를 변경했는데, 새 호스트에서 복호화 실패.

원인: publicKeys 변경 후 `cd secrets && nix run github:ryantm/agenix -- -r` (재암호화) 미실행. `.age` 파일은 변경 시점의 recipient 목록으로 암호화되어 있으므로, publicKeys를 변경한 후 반드시 재암호화해야 한다.

해결:

```bash
# 모든 .age 파일을 secrets.nix의 최신 publicKeys로 재암호화
cd secrets && nix run github:ryantm/agenix -- -r
```

호스트 키 변경 시: 해당 호스트의 SSH 키가 재생성된 경우, `secrets/secrets.nix`에서 공개키를 업데이트한 후 재암호화.

---

## 배포 후 파일 미생성

증상: `nrs` 실행 후 secret 파일이 기대 경로에 없음 (예: `~/.config/pushover/` 아래에 파일 없음).

원인:

1. `modules/shared/programs/secrets/default.nix`에 배포 설정이 누락됨
2. Home Manager agenix 서비스가 정상 작동하지 않음
3. `.age` 파일이 아직 생성되지 않음

진단:

```bash
# 배포된 파일 확인
ls -la ~/.config/pushover/

# Home Manager 서비스 상태 확인 (NixOS)
systemctl --user status agenix

# .age 파일 존재 여부
ls -la secrets/*.age
```

해결:

1. `modules/shared/programs/secrets/default.nix`에 배포 설정 추가
2. `nrs`로 재빌드
3. 배포 경로에서 파일 존재 확인

---

## macOS agenix launchd agent crash loop (.tmp 파일 잔류)

> 발생 시점: 2026-02-18
> 해결: stale generation 정리 + 예방 코드 추가

증상: `nrs` 후 일부 시크릿이 복호화되지 않음. `~/Library/Logs/agenix/stderr`에 아래 에러 반복:

```
age: error: open /Users/<user>/.local/state/agenix.d/<N>/<secret>.tmp: permission denied
```

(2026-08 이전 사고 당시 경로는 `$TMPDIR/agenix.d`였다 — 현재 darwin 배치는
`~/.local/state/agenix.d`이며 정본은 `constants.paths.agenixDarwinSecretsRelPath`.)

원인: `nrs`의 launchd cleanup이 복호화 중인 agenix agent를 kill → 0400 권한의 `.tmp` 파일이 다음 generation 디렉토리에 남음 → agent 재시작 시 해당 `.tmp`를 덮어쓸 수 없어 crash loop.

진단:

```bash
# agenix generation 디렉토리 확인 (경로 정본: constants.paths.agenixDarwinSecretsRelPath)
ls -la ~/.local/state/agenix.d/

# 깨진 generation에 .tmp 파일 확인
find ~/.local/state/agenix.d/ -name '*.tmp'

# agenix 에러 로그 확인
tail -20 ~/Library/Logs/agenix/stderr
```

수동 해결:

```bash
# 예방 코드(cleanupAgenixStaleGenerations)가 안전한 순서 전체를 이미 수행한다:
# OS 버전 분기된 bootout 완료 대기(26+는 --wait, 미만은 성공 후 1초 대기) →
# 성공 또는 미로드일 때만 삭제 → setupLaunchAgents 재bootstrap.
# 수동으로 bootout/rm을 복제하지 말고 activation 재실행 한 번으로 복구한다.
# (일반 nrs는 시스템 구성이 같으면 activation을 생략하므로 --force 필수)
nrs --force
```

수동으로 개별 명령을 실행해야 하는 예외 상황(예: nrs 자체가 불가)이라면, 위 예방 코드(`modules/shared/programs/secrets/default.nix`)의 순서와 조건을 그대로 따른다 — bootout이 성공하거나 명시적 미로드("No such process")일 때만 삭제하고, macOS 26 미만에서는 `--wait` 없이 bootout 후 1초 대기한다.

예방 코드: `modules/shared/programs/secrets/default.nix`에 `cleanupAgenixStaleGenerations` activation이 추가됨. `setupLaunchAgents` 전에 `.tmp` 파일이 있는 stale generation과, `secretsDir` 심링크가 가리키지 않는 orphan generation을 자동 삭제한다 — 주 발생 경로는 복호화 도중 kill(아직 링크되지 않은 신 generation, `.tmp` 없는 변형 포함)이고, 심링크 전환 직후 직전 generation `rm -rf`가 끝나기 전 kill로 남는 구 generation도 같은 분기가 잡는다 (이전 bootout 실패는 발생 원인이 아니라 잔재 유지 사유다). `.tmp`는 "agent가 지금 쓰는 중"의 표시일 수도 있으므로, 삭제 전에 `launchctl bootout`으로 agent를 내려 writer와 rm을 직렬화한다 — 쓰는 중인 generation을 그냥 rm -rf하면 ENOTEMPTY로 실패해 activation이 중단되거나(2026-08-12 사례), 완성된 secret 일부만 지워진 불완전 generation이 조용히 배포될 수 있다. bootout 계약은 home-manager launchd 모듈의 `bootoutAgent`와 동일하다: macOS 26+는 `--wait`로 종료 완료를 보장, 이전 버전은 성공 후 1초 대기, "No such process"류만 미로드(harmless)로 통과하고 그 외 실패 시에는 활성 writer가 남았을 수 있으므로 그 회차의 삭제를 건너뛴다. bootout된 agent는 `setupLaunchAgents`가 다시 bootstrap하고(home-manager는 plist unchanged라도 not-loaded job을 재로드) RunAtLoad 1회 실행이 완전한 fresh generation을 재생성한다. 정리 대상(`.tmp` 잔재 또는 심링크 밖 orphan)이 없으면 bootout 없이 통과하므로 정상 경로에는 개입이 없다 — upstream이 매 실행 직전 generation을 지우므로 정상 상태의 mount에는 활성 generation 하나만 남는다. rm 실패는 non-fatal (경고 후 다음 activation에서 재시도).

영속 경로 롤백 잔재: darwin 시크릿을 영속 경로(`~/.local/state/agenix{,.d}`)로 배치한 구성에서 구 구성(TMPDIR 배치)으로 롤백해 머무는 경우, 구 구성은 신 경로를 모르므로 평문 generation을 회수할 주체가 없다 (dirhelper도 홈 아래는 청소하지 않는다). 신 구성을 다시 적용하면 upstream의 직전 generation 삭제가 회수하지만, 재적용 계획 없이 롤백 상태를 유지한다면 수동으로 회수한다 — 먼저 `readlink ~/.config/pushover/share`(공통 attrset 배포라 personal·work 양쪽 darwin 호스트에 존재)가 `/var/folders/...`(구 경로)를 가리키는지 확인해 구 구성 활성을 확정한 뒤 `rm -rf ~/.local/state/agenix ~/.local/state/agenix.d`.

---

## macOS agenix launchd agent 무한 재스폰 루프 (KeepAlive 의미론)

> 발생 시점: 2026-08-12 진단 (루프 자체는 최소 2026-01부터 만성)
> 해결: `KeepAlive` override (`modules/shared/programs/secrets/default.nix`)

증상: agent가 성공(exit 0)해도 5~15초마다 무한 재실행. `~/Library/Logs/agenix/stdout`이 수백 MB로 비대해지고, generation 번호가 부팅 세션당 수만까지 증가. `nrs`의 `cleanupAgenixStaleGenerations`가 쓰기 중인 generation과 race해 간헐적으로 activation이 죽는 2차 피해 유발.

원인: upstream `ryantm/agenix`의 `age-home.nix`가 `KeepAlive = { Crashed = false; SuccessfulExit = false; }`를 선언. `launchd.plist(5)`에서 `Crashed = false`는 "crash가 아닌 종료라면 재시작"(inverse condition)이라, oneshot mount 스크립트의 정상 종료마다 재스폰이 발동한다.

진단:

```bash
# runs가 비정상적으로 크고 state가 spawn scheduled면 루프 중
launchctl print "gui/$(id -u)/org.nix-community.home.activate-agenix" | grep -E "state|runs|last exit"

# 스폰 사유가 semaphore(KeepAlive)인지 확인
launchctl blame "gui/$(id -u)/org.nix-community.home.activate-agenix"

# 배포된 plist에 Crashed 키가 없어야 정상 (override 적용 확인)
grep -A3 KeepAlive ~/Library/LaunchAgents/org.nix-community.home.activate-agenix.plist
```

해결: `launchd.agents.activate-agenix.config.KeepAlive`를 `lib.mkForce { SuccessfulExit = false; }`로 override — 실패 시 재시도라는 upstream 의도는 보존하고 non-crash 재스폰 조건만 제거한다.

---

## macOS agenix 시크릿이 home.activation 시점에 없음

> 발생 시점: 2026-02-18

증상: `home.activation` 스크립트에서 agenix 시크릿 파일을 참조하면 "not found".

원인: macOS에서 agenix는 `home.activation`이 아닌 `launchd.agents.activate-agenix` (RunAtLoad)로 시크릿을 복호화한다. `setupLaunchAgents`가 agent를 로드해야 복호화가 시작되므로, 그 이전 activation 단계에서는 시크릿이 없다.

해결: 시크릿을 참조하는 activation 단계를 `setupLaunchAgents` 이후로 배치 + 짧은 polling.

```nix
home.activation.myStep =
  lib.hm.dag.entryAfter [ "setupLaunchAgents" ]
    ''
      _waited=0
      while [ ! -f "/path/to/secret" ] && [ "$_waited" -lt 5 ]; do
        sleep 1
        _waited=$(( _waited + 1 ))
      done
      # ... 시크릿 사용
    '';
```
