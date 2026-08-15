# Host Handling

## `--hosts` 인자 파싱

```python
import argparse

VALID_HOSTS = {"mac", "minipc"}

parser.add_argument(
    "--hosts",
    type=lambda s: [h.strip() for h in s.split(",")],
    default=["mac", "minipc"],
    help="comma-separated host list. choices: mac, minipc"
)

args = parser.parse_args()
for h in args.hosts:
    if h not in VALID_HOSTS:
        parser.error(f"invalid host: {h!r}. valid: {sorted(VALID_HOSTS)}")
```

whitelist reject-fast 의무: `{mac, minipc}` 외 값은 즉시 거부. user-controlled 입력이 SSH alias로 들어가는 경계 보호.

## SSH alias 매핑

각 호스트의 SSH alias는 `~/.ssh/config`의 `Host mac` / `Host minipc` 정의에 의존한다. 본 Skill은 alias가 동작한다고 가정한다 (alias 부재 시 SSH 명령이 실패 → partial result).

| 현재 머신 | mac 대상 | minipc 대상 |
|-----------|----------|-------------|
| Mac (Darwin) | local | `ssh minipc` |
| MiniPC (NixOS Linux) | `ssh mac` | local |

현재 머신 판별: `platform.system()`이 `"Darwin"`이면 Mac, `"Linux"`이면 MiniPC (현재 NixOS 호스트는 MiniPC 1대뿐 — 호스트 추가 시 `hostname` 보강 필요).

## SSH 호출 패턴 (subprocess.run 고정 argv + remote path 검증)

shell string 금지. 항상 list argv 형태로 subprocess.run 호출. 단 ssh remote command는 원격 shell이 해석하므로 path 안의 shell metacharacter / 제어문자도 거부해야 명령 인젝션을 차단한다 — argv 고정만으로는 충분하지 않다. `analyze.py`의 `_allowed_remote_path` 검증이 SoT.

검증 조건:
- 다음 문자 부재: space, newline, carriage return, tab, `; | & $ \` ( ) { } [ ] < > * ? " ' \\`.
- 확장자 `.jsonl`로 종결.
- `posixpath.normpath`로 traversal(`../`) 정규화.
- `posixpath.isabs`로 relative path 폐기 (find stdout이 비정상으로 relative line을 내보낸 경우).
- `posixpath.commonpath([base_norm, path_norm]) == base_norm and path_norm != base_norm` boundary 비교 — sibling-prefix(`/Users/greenhead/.claude/projects-evil/x.jsonl`) 거부, absolute/relative mix는 ValueError로 폐기.
- 비교 대상 base는 `HOST_PATH_MAP[host]["claude"]` 또는 `HOST_PATH_MAP[host]["codex"]` absolute prefix.

검증 실패 시 `ValueError` 또는 (find stdout 처리에서는) silently 폐기.

```python
def _allowed_remote_path(host: str, path: str) -> bool:
    if not isinstance(path, str) or not path:
        return False
    if any(c in path for c in " \n\r\t;|&$`(){}[]<>*?\"'\\"):
        return False
    if not path.endswith(".jsonl"):
        return False
    try:
        path_norm = posixpath.normpath(path)
    except Exception:
        return False
    if not posixpath.isabs(path_norm):
        return False
    paths = HOST_PATH_MAP.get(host, {})
    bases = (paths.get("claude", ""), paths.get("codex", ""))
    for base in bases:
        if not base:
            continue
        base_norm = posixpath.normpath(base)
        try:
            if posixpath.commonpath([base_norm, path_norm]) == base_norm and path_norm != base_norm:
                return True
        except ValueError:
            continue
    return False
```

금지:
- `subprocess.run(f"ssh {alias} cat {path}", shell=True)` — 인젝션 위험.
- `os.system(...)` — 인젝션 위험.
- `subprocess.run(["bash", "-c", ...])` — shell 경유.

허용 + 의무:
- `subprocess.run(["ssh", alias, "find", base, ...], capture_output=True)` — argv 고정.
- MiniPC: `subprocess.run(["ssh", alias, "tar", "-C", "/", "-cf", "-", "-T", "-"], input=...)` — argv 고정. file list는 stdin으로만 전달.
- macOS: `subprocess.run(["ssh", alias, "env", "COPYFILE_DISABLE=1", "tar", "-C", "/", "-cf", "-", "-T", "-"], input=...)` — 고정 env/argv로 AppleDouble metadata 생성을 억제.
- `subprocess.run(["ssh", alias, "cat", path], ...)` — tar batch 실패 시 fallback. path는 `_allowed_remote_path` 통과 후에만.

remote `find` stdout의 path line은 비신뢰 입력으로 간주. 각 line을 `_allowed_remote_path`로 다시 검증하여 통과한 line만 수집한다.

## preflight + host fetch budget

원격 host는 파일 수집을 시작하기 전에 저비용 생존 확인을 먼저 수행한다.

- Python 수집 preflight command는 `ssh -o ConnectTimeout=10 <alias> true`이며,
  subprocess timeout도 `SSH_CONTROLMASTER_CHECK_TIMEOUT_SECONDS = 10`을 사용한다.
  `BatchMode=yes`는 붙이지 않는다. 아래 cron retry-window shell preflight는
  `BatchMode=yes`를 붙이고 별도 subprocess timeout 없이 SSH `ConnectTimeout`에 의존한다.
  언어/실행 경계가 달라 통합하지 않으며, 한쪽 timeout/BatchMode 계약을 바꿀 때는
  `analyze.py`, `da-weekly-report.sh`, 본 문서를 함께 갱신한다.
- preflight 실패/timeout/binary 부재는 해당 host를 즉시 partial 처리하고, `find`, `tar`,
  `cat` fetch를 시도하지 않는다.
- ControlMaster mux socket 존재만으로 생존 판정하지 않는다. mux가 살아 있어도 상대 Mac이
  절전/무응답이면 `ssh ... true` preflight 또는 subprocess timeout으로 fast-fail해야 한다.
- preflight 성공 후 `HostFetchBudget`을 시작한다. `SSH_HOST_FETCH_BUDGET_SECONDS = 600`이며,
  remote `find` 시작부터 해당 host의 `find + tar batch 또는 per-file cat fallback` 전체를
  같은 wall-clock deadline으로 제한한다.
- 각 SSH 호출 timeout은 기존 per-call timeout과 host budget 잔여 시간 중 더 작은 값으로
  clamp한다. budget이 소진되면 남은 수집은 시작하지 않고 partial warning을 남긴다.
- preflight 이후 수행되는 `ssh -O check <host>` ControlMaster 확인도 host budget 잔여
  시간 안에서만 실행한다.
- budget warning 문구는 `host <name>: ssh fetch budget 초과 — remote 수집 중단, partial result`
  형식을 유지한다. `host <name>:` prefix는 weekly coverage의 host partial 판정 입력이므로,
  실패가 아닌 사건(아래 size cap 제외 등)에는 이 prefix를 쓰지 않는다. 문구에 `ssh` 토큰을
  포함하는 것도 계약이다 — weekly report의 warning 카테고리 분류 입력이다.

### corpus size cap

- `REMOTE_FILE_SIZE_CAP_MB = 50`. 원격 `find`는 바이트 suffix로 상한을 건다 — 수집은
  `-size -<cap+1>c`, 초과 카운트는 `-size +<cap>c`로 상보 분할한다 (`REMOTE_FIND_SIZE_INCLUDE`
  /`REMOTE_FIND_SIZE_EXCLUDE`). 로컬 수집(`collect_local_files`)도 같은 바이트 경계를 쓴다 —
  corpus 정의가 실행 위치에 따라 달라지지 않게 하기 위함이다.
- `M` suffix를 쓰지 않는 이유: `find -size`의 `M` 의미가 구현마다 다르다. GNU는 크기를 MB
  단위로 올림해 비교하므로 `-50M`/`+50M` 사이에 1MiB 폭의 구간이 수집에도 초과 카운트에도
  잡히지 않고, BSD는 바이트 정확 비교라 갭이 cap 값 한 점이다. 어느 쪽이든 침묵 절단이
  생긴다. `c` suffix는 양 구현 모두 바이트 정확 비교라 로컬 `os.path.getsize` 판정과 경계가
  일치한다. 재검증: 경계 전후 크기의 fixture를 만들어 `find -size -<cap+1>c`와
  `-size +<cap>c`의 합이 전체와 같은지 두 구현에서 확인한다.
- 이 cap은 "신호 없는 파일 제외"가 아니라 의도적 corpus 편향이다. 크기는 verdict 신호의
  판별자가 아니며(초과분에도 verdict가 존재한다), 수집 가용성을 위해 일부 실제 verdict를
  버리는 trade-off다. 도입 배경은 2026-08 mac `~/.codex/sessions` 폭증으로 인한 budget 초과
  (mac 수집 4주 연속 0건).
- 제외 건수는 `warnings`가 아니라 sidecar의 `corpus_exclusions[]`(host/base/reason/cap_mb/
  excluded_files)에 기록하고, weekly coverage는 이를 `host_collection[host].excluded_files`로
  노출한다. 제외는 실패가 아니므로 host `status`·리포트 `partial` 판정에 영향을 주지 않는다.

## fetch 전략: tar batch 우선 + per-file cat fallback

원격 host의 파일 수집은 기존 `find` 목록 수집을 유지한 뒤, 검증된 목록 전체를 단일 tar stream으로 전송한다.

1. `collect_remote_files(host, warnings)`는 기존처럼 `find ~/.claude/projects ...`와 `find ~/.codex/sessions ...`를 실행하고, stdout line마다 `_allowed_remote_path(host, line)`을 통과한 path만 반환한다.
2. remote host 분석 직전 `_prepare_remote_tar_entries(host, files, warnings)`가 목록을 다시 검증한다. `HOST_PATH_MAP` base prefix, shell metacharacter/제어문자 거부, `.jsonl` 확장자, `posixpath.normpath`, absolute path, `posixpath.commonpath` boundary 조건은 `_allowed_remote_path`와 동일하게 적용한다.
3. tar list는 `tar -C /` 기준 상대 path로 변환한다. 예: `/Users/greenhead/.claude/projects/a.jsonl` → `Users/greenhead/.claude/projects/a.jsonl`.
4. file name에 newline 또는 carriage return이 포함된 path는 `tar -T -`의 newline 구분 형식으로 안전하게 표현할 수 없으므로 제외하고 warning을 남긴다. 제외된 path는 per-file fallback에서도 fetch하지 않는다.
5. fetch command는 MiniPC에서 `ssh <alias> tar -C / -cf - -T -`, macOS에서
   `ssh <alias> env COPYFILE_DISABLE=1 tar -C / -cf - -T -`이며 file list는 stdin으로
   넘긴다. 고정된 macOS 환경변수는 요청 파일과 함께 생성되는 AppleDouble `._*` metadata
   member를 억제한다. tar 옵션 조합은 GNU tar(리눅스)와 bsdtar(macOS) 공통 surface다.
6. 로컬 extractor는 tar member의 raw path component에 `..`가 있는지 정규화 전에 거부하고,
   정규화된 상대 path가 요청 allowlist와 정확히 일치하는지 다시 확인한다. 일치한 member도
   regular file이어야 하며 최종 destination은 임시 디렉토리 boundary 안이어야 한다.
   AppleDouble `._*`, 요청하지 않은 unknown member, traversal, non-regular member는 payload로
   채택하지 않고 validation warning으로 남긴다. 이 경계는 `_allowed_remote_path`, newline
   거부, tar member allowlist를 대체하거나 약화하지 않는다.
7. 검증을 통과해 추출된 로컬 파일만 `analyze_session(..., logical_path=<remote absolute path>)`로 분석한다. 임시 디렉토리는 함수 종료 시 정리한다.
8. tar fetch가 timeout, ssh binary 부재, nonzero exit, 빈 stdout, tar 해석 실패, extractable file 0건 중 하나로 실패하면 warning을 남기고 기존 per-file `ssh <alias> cat <path>` worker pool로 fallback한다. 단, 실패 시점에 host budget이 소진되었으면 fallback으로 내려가지 않고 해당 host의 남은 수집을 중단한다.

ControlMaster 정책은 tar batch와 fallback 모두 동일하다. remote host는 fetch 전에 `ssh -o ConnectTimeout=10 <host> true` preflight와 `check_controlmaster_active()`를 통과해야 하며, ControlMaster 비활성 시 host 전체 fetch를 skip한다. 이 경우 per-file fallback으로 강등하지 않는다.

## Command path vs validation/corpus path 역할 분리

`HOST_PATH_MAP`의 absolute home prefix (`/Users/greenhead/...`, `/home/greenhead/...`)는 SSH 명령 인자에 직접 들어가지 않는다. 명령 인자에는 host-neutral relative tilde 표현 (`~/.claude/projects`, `~/.codex/sessions`)을 사용해 host별 home directory hardcoded를 명령 구성에서 제거한다. 원격 shell이 `~`를 해당 user의 home으로 expansion한다.

absolute prefix는 다음 두 용도로만 사용한다:

1. Validation path: `_allowed_remote_path`가 SSH find stdout (비신뢰 입력) 각 line을 검증할 때 boundary 비교 기준으로 사용한다. `posixpath.normpath` + `posixpath.commonpath([base_norm, path_norm]) == base_norm` 비교로 sibling-prefix (`/Users/greenhead/.claude/projects-evil/...`), traversal (`../../etc/shadow`), relative path (find stdout이 비정상으로 relative line을 내보낸 경우)를 모두 거부한다.
2. Corpus path: `--corpus manifest.json` 모드에서 host 분류 prefix로도 사용한다 (`HOST_PATH_MAP` base prefix 순회). 미매칭 path는 silent host 배정 대신 warning만 누적한다 — 새 host 지원은 `HOST_PATH_MAP`에 명시 추가가 정답이다.

이 역할 분리는 PR review thread의 `HOST_PATH_MAP` fragility 질문에 답한다 — 명령 구성에서는 hardcoded prefix를 제거하지만, 보안 경계와 corpus host inference에는 absolute prefix가 SSOT로 남는다 (host model 중앙화는 별도 PR로 분리, 본 reference의 NG-3 참조).

`--host-home host=/abs/home`은 위 absolute prefix의 optional override다. override 후
`HOST_PATH_MAP[host]["claude"] = /abs/home/.claude/projects`,
`HOST_PATH_MAP[host]["codex"] = /abs/home/.codex/sessions`로 재계산한다. SSH command path는
계속 `~/.claude/projects` / `~/.codex/sessions`를 사용하므로, override는 validation/corpus
boundary에만 영향을 준다. host 값은 `{mac,minipc}` whitelist를 유지하고 home 값은 absolute
path여야 한다.

## remote command allowlist

원격 호스트에서 실행 가능한 명령은 다음으로 제한:
- `find <prefix> -type f -name "*.jsonl"` (path glob)
- `tar -C / -cf - -T -` (검증된 file list를 stdin으로 받아 batch read; macOS에서는
  고정 prefix `env COPYFILE_DISABLE=1`로 AppleDouble metadata 생성을 억제)
- `cat <path>` (tar batch 실패 시 파일 내용 read fallback)
- `stat <path>` (파일 메타 — 선택)
- `true` (원격 생존 확인 및 ControlMaster master 생성/활성 확인용 transport control). `ssh -O check <host>` 자체는 client 측 multiplex control이며 원격 명령을 실행하지 않는다.

`rm`, `mv`, `mkdir`, `git`, `curl`, `wget` 등은 사용하지 않는다 (read-only 분석 의도).

## partial result 처리

SSH 호출이 실패한 호스트/파일은 측정에서 제외하고 `warnings` 리스트에 명시적 경고를 누적한다 (silent fallback 금지). 실패 단계마다 `warnings`에 누적해야 하며, 함수는 `None` 또는 빈 list를 반환하여 caller가 partial result 흐름을 이어가게 한다.

`analyze.py`의 패턴:
- `check_remote_host_preflight(host, warnings)`: `ssh -o ConnectTimeout=10 <host> true` 실패/timeout/binary 부재 시 `warnings`에 누적 후 `False` 반환. caller는 해당 host fetch를 시작하지 않는다.
- `collect_remote_files(host, warnings)`: `find` 명령 timeout / ssh binary 부재 / nonzero rc 모두 `warnings`에 누적 후 빈 list 반환.
- `analyze_remote_sessions_via_tar(host, entries, warnings)`: tar batch 실패는 `warnings`에 누적 후 `None` 반환. caller는 기존 per-file cat fallback을 실행한다.
- `fetch_remote_file(host, path, warnings)`: `cat` 명령 timeout / ssh binary 부재 / nonzero rc 모두 `warnings`에 누적 후 `None` 반환.
- `analyze_remote_session(host, path, warnings)`: `fetch_remote_file` 반환이 `None`이면 그대로 `None` 반환 → caller가 sessions 리스트에 append하지 않는다.
- `HostFetchBudget`: host budget 소진 시 `host <name>: ssh fetch budget 초과 — remote 수집 중단, partial result` warning을 한 번 남기고, 남은 remote 수집을 시작하지 않는다.
- size cap 제외는 이 partial 계열이 아니다 — `corpus_exclusions[]`로 분리 기록한다 (위 "corpus size cap" 참조).

markdown stdout 출력에는 footer에 warnings 섹션이 추가된다:

```markdown
---
⚠ Warnings:
- host minipc: SSH timeout — partial result
```

JSON sidecar의 `warnings` 배열에도 같은 메시지가 들어간다.

## cron/systemd 주간 리포트 경로

NixOS 자동 실행은 Skill slash-command 호출이 아니라 system service
`da-weekly-report.service`가 `analyze.py`를 직접 실행하는 경로다. 실행 주체는
`User = username`, `Group = "users"`이고, `HOME=/home/<username>`을 명시한다. 따라서 SSH
alias `mac`, ControlMaster socket, `~/.codex/config.toml`, Pushover user credential은
interactive user-scope와 같은 파일을 사용한다.

systemd 호출부는 `--host-home mac=/Users/<username>,minipc=/home/<username>`을 항상 전달한다.
이 값은 `HOST_PATH_MAP` validation/corpus/traceability prefix만 바꾸며, SSH command path는
계속 `~/.claude/projects`, `~/.codex/sessions`다.

주간 자동화는 MacBook 절전과 사용자 기상 시각 변동을 전제로 retry window를 가진다.
`da-weekly-reminder.timer`는 일요일 22:00 KST에 Pushover 사전 리마인더를 1회 보낸다
(helper/credential 부재 또는 전송 실패는 fail-soft). `da-weekly-report.timer`는 월요일
09:00~14:00 KST 매시 발행을 시도한다.

`da-weekly-report.sh`는 시작 시 이번 주 final core JSON(`weekly-<ISO-week>.json`)이 이미
있으면 analyzer와 LLM을 재실행하지 않는다. local full Markdown이 없거나 비었으면 canonical
JSON에서 원자적으로 복구한 뒤, publish log를 읽어 target별 마지막 status가 미기록이거나
`failed`/`blocked`인 target(`github`, `pushover`)만 재시도한다. `success`/`skipped`는
terminal status이며 재시도하지 않는다. GitHub 재시도 body는 full Markdown을 재사용하지 않고
final canonical JSON에서 bounded projection을 매번 다시 생성한다. 아직 final core JSON이 없으면 `HOSTS`에서 현재 host를
제외해 remote host 목록을 만들고, 각 remote host에
`ssh -o ConnectTimeout=10 -o BatchMode=yes <host> true` preflight를 1회 수행한다. shell
preflight는 `BatchMode=yes`를 붙이고 Python `check_remote_host_preflight`
와 달리 별도 subprocess timeout이 없다. 이 차이는 intentional dual implementation 계약이며,
한쪽 timeout/BatchMode를 바꿀 때는 양쪽 callsite 주석과 본 문서를 함께 갱신한다. remote host가
무응답이고 `WINDOW_WEEKDAY`/`WINDOW_START_HOUR`/`WINDOW_DEADLINE_HOUR`/`WINDOW_TIMEZONE`
기준 retry deadline 전이면 `attempt-<ISO-week>.state`에 알림 claim을 남긴 첫 실패에만 Pushover
sleep alert를 보낸 뒤 exit 0으로 다음 정시 발화를 기다린다. 이미 claim된 주차의 추가 실패는
조용히 성공 종료한다. configured weekday의 deadline 이후 발화와 Persistent catch-up 발화에서는
preflight 실패가 있어도 pipeline을 계속 진행한다.

LLM commentary subprocess는 scratch cwd, read-only sandbox, `--ignore-user-config`,
`--ignore-rules`, `--ephemeral`, secret 관련 env unset으로 실행한다. stdin에는 full draft가 아니라
`render_commentary_input()`이 만든 bounded projection만 전달한다. finalize의 기존 commentary
sanitize gate는 secret source read 실패를 best-effort로 처리하고 commentary 자체를 폐기하는
방어선으로 유지한다.

GitHub 호출 직전에는 별도의 fail-closed guarded publisher가 token/secret source를 경로별 한 번만
읽어 snapshot을 만든다. 동일 snapshot으로 공개 대상 projection의 모든 문자열 값과 최종 UTF-8
body bytes를 각각 대조하며, match·unreadable·empty/unparsed source·projection 실패 시 `gh`를
호출하지 않는다. stdout/stderr와 append-only publish message에는 body, secret value, credential
path, raw publisher stderr를 남기지 않는다. GitHub가 blocked/failed여도 pending Pushover target은
계속 처리한다. 같은 UID 프로세스가 user-readable secret 파일 자체를 읽는 잔여 경계는 변하지
않지만, exact outbound body는 발행 직전 snapshot으로 다시 검증된다.

Mac 수집 실패 또는 ControlMaster 비활성은 weekly pipeline의 hard fail이 아니다. 마감 발화
또는 직접 실행에서 `analyze.py`는 해당 host warning을 sidecar에 남기고, `da-weekly-report.sh`는
sidecar가 존재하면 weekly JSON/markdown을 계속 생성한다. `weekly_report.py`는 이를
`coverage.partial = true`와 `coverage.host_collection.mac.status = "partial"`로 승격한다.
주간 markdown의 커버리지/신뢰도 표와 warnings 섹션이 "Mac 미수집"에 해당하는 host warning을
노출한다.

## Mac/MiniPC 경로 매핑 기본값

| 호스트 | Claude Code base | Codex base |
|--------|-----------------|------------|
| mac | `/Users/greenhead/.claude/projects/` | `/Users/greenhead/.codex/sessions/` |
| minipc | `/home/greenhead/.claude/projects/` | `/home/greenhead/.codex/sessions/` |

위 표는 현재 배포 사용자(`greenhead`) 기준 하위호환 기본값이다. username migration을 고려한
자동 실행 환경에서는 하드코딩하지 않고 `--host-home mac=/Users/<username>,minipc=/home/<username>`을
명시 전달한다. 이 값은 validation/corpus prefix와 traceability host inference에만 쓰이며,
SSH command path는 계속 `~/.claude/projects` / `~/.codex/sessions`다.

`--corpus manifest.json` 사용 시 위 표의 `HOST_PATH_MAP` base prefix를 우선 순회하여 host를 분류한다. 미매칭 path는 `warnings` 누적 후 처리에서 제외 — 새 host 지원은 `HOST_PATH_MAP` 추가가 정답이다 (silent host 배정 회피).
