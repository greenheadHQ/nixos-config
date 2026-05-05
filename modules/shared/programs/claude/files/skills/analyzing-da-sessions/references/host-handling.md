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

**whitelist reject-fast 의무**: `{mac, minipc}` 외 값은 즉시 거부. user-controlled 입력이 SSH alias로 들어가는 경계 보호.

## SSH alias 매핑

각 호스트의 SSH alias는 `~/.ssh/config`의 `Host mac` / `Host minipc` 정의에 의존한다. 본 Skill은 alias가 동작한다고 가정한다 (alias 부재 시 SSH 명령이 실패 → partial result).

| 현재 머신 | mac 대상 | minipc 대상 |
|-----------|----------|-------------|
| Mac (Darwin) | local | `ssh minipc` |
| MiniPC (NixOS Linux) | `ssh mac` | local |

현재 머신 판별: `platform.system()`이 `"Darwin"`이면 Mac, `"Linux"`이면 MiniPC (현재 NixOS 호스트는 MiniPC 1대뿐 — 호스트 추가 시 `hostname` 보강 필요).

## SSH 호출 패턴 (subprocess.run 고정 argv + remote path 검증)

shell string 금지. 항상 list argv 형태로 subprocess.run 호출. **단 ssh remote command는 원격 shell이 해석하므로 path 안의 shell metacharacter / 제어문자도 거부해야 명령 인젝션을 차단한다** — argv 고정만으로는 충분하지 않다. `analyze.py`의 `_allowed_remote_path` 검증이 SoT.

검증 조건:
- path가 `HOST_PATH_MAP[host]["claude"]` 또는 `HOST_PATH_MAP[host]["codex"]` base prefix 아래 (`os.sep` 포함).
- 확장자 `.jsonl`로 종결.
- 다음 문자 부재: newline, carriage return, tab, `; | & $ \` ( ) { } [ ] < > * ? " ' \\`.

검증 실패 시 `ValueError` 또는 (find stdout 처리에서는) silently 폐기.

```python
def _allowed_remote_path(host: str, path: str) -> bool:
    if not isinstance(path, str) or not path:
        return False
    if any(c in path for c in "\n\r\t;|&$`(){}[]<>*?\"'\\"):
        return False
    if not path.endswith(".jsonl"):
        return False
    paths = HOST_PATH_MAP.get(host, {})
    bases = (paths.get("claude", ""), paths.get("codex", ""))
    return any(b and path.startswith(b + os.sep) for b in bases)
```

**금지**:
- `subprocess.run(f"ssh {alias} cat {path}", shell=True)` — 인젝션 위험.
- `os.system(...)` — 인젝션 위험.
- `subprocess.run(["bash", "-c", ...])` — shell 경유.

**허용 + 의무**:
- `subprocess.run(["ssh", alias, "find", base, ...], capture_output=True)` — argv 고정.
- `subprocess.run(["ssh", alias, "cat", path], ...)` — argv 고정. **path는 `_allowed_remote_path` 통과 후에만**.

remote `find` stdout의 path line은 **비신뢰 입력**으로 간주. 각 line을 `_allowed_remote_path`로 다시 검증하여 통과한 line만 수집한다.

## remote command allowlist

원격 호스트에서 실행 가능한 명령은 다음으로 제한:
- `find <prefix> -type f -name "*.jsonl"` (path glob)
- `cat <path>` (파일 내용 read)
- `stat <path>` (파일 메타 — 선택)

`rm`, `mv`, `mkdir`, `git`, `curl`, `wget` 등은 사용하지 않는다 (read-only 분석 의도).

## partial result 처리

SSH 호출이 실패한 호스트/파일은 측정에서 제외하고 `warnings` 리스트에 명시적 경고를 누적한다 (silent fallback 금지). 실패 단계마다 `warnings`에 누적해야 하며, 함수는 `None` 또는 빈 list를 반환하여 caller가 partial result 흐름을 이어가게 한다.

`analyze.py`의 패턴:
- `collect_remote_files(host, warnings)`: `find` 명령 timeout / ssh binary 부재 / nonzero rc 모두 `warnings`에 누적 후 빈 list 반환.
- `fetch_remote_file(host, path, warnings)`: `cat` 명령 timeout / ssh binary 부재 / nonzero rc 모두 `warnings`에 누적 후 `None` 반환.
- `analyze_remote_session(host, path, warnings)`: `fetch_remote_file` 반환이 `None`이면 그대로 `None` 반환 → caller가 sessions 리스트에 append하지 않는다.

markdown stdout 출력에는 footer에 warnings 섹션이 추가된다:

```markdown
---
⚠ Warnings:
- host minipc: SSH timeout — partial result
```

JSON sidecar의 `warnings` 배열에도 같은 메시지가 들어간다.

## Mac/MiniPC 경로 매핑

| 호스트 | Claude Code base | Codex base |
|--------|-----------------|------------|
| mac | `/Users/green/.claude/projects/` | `/Users/green/.codex/sessions/` |
| minipc | `/home/greenhead/.claude/projects/` | `/home/greenhead/.codex/sessions/` |

`--corpus manifest.json` 사용 시 path prefix(`/Users/` 또는 `/home/`)로 host 자동 분류.
