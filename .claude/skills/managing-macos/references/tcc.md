# macOS TCC 원격 세션 운영

## 선언 경계

macOS TCC는 Files & Folders, App Data, Full Disk Access 같은 privacy decision을 별도
database에 보관한다. nix-darwin/Home Manager가 앱 설치, bundle 위치, launcher, 정책 자료를
관리할 수는 있지만 일반 preference처럼 TCC grant를 직접 쓰는 지원 API는 없다.

| Surface | Nix가 선언 가능한 것 | 실제 decision 적용 주체 |
|---|---|---|
| 수동 Files & Folders/FDA | 앱 설치, 기대 identity, runbook, validator | 운영자 + System Settings |
| managed PPPC | payload, exact identity, MDM service config, validator | user-approved MDM |
| Claude/Codex internal permission | settings/launcher argv | Claude/Codex runtime; macOS TCC와 무관 |

`tccutil`은 reset 도구이지 grant API가 아니다. TCC DB 직접 수정, SIP 비활성화, broad reset,
GUI 자동화 우회로 declarative state를 흉내내지 않는다.

Issue #1093의 선택 정책은 Claude의 persistent `additionalDirectories`를 `~/Workspace`로
제한하고 보호 폴더는 세션별 `/add-dir` 또는 시작 시 `--add-dir`로 opt-in하는 C와, Ghostty
direct에 FDA를 사용하는 D다. D는 launchd Claude/Codex App remote 권한을 대신하지 않는다.

초기 A targeted grant는 repo/보호 폴더 및 같은 ChatGPT app session의 반복 `nrs`에서
통과했지만, ChatGPT를 재실행한 뒤 같은 bundle/team identity에서
`SystemPolicyAppData` prompt가 다시 발생했다. 따라서 Mac 앞에 없는 remote DX의 지속 정책으로
채택하지 않는다. B는 launcher별 identity에 따로 적용할 수 있는 후보지만, ChatGPT bundle과
달리 launchd Claude 쪽에는 update 때 drift하는 versioned Nix bash 외 지속 가능한 responsible
identity가 없어 두-launcher matrix를 완성할 수 없었다. 권한이 넓다는 이유로 B를 자동 기각한
것은 아니다.

Claude의 `additionalDirectories`, `/add-dir`, `--add-dir`는 Claude 내부에서 선언하는 작업
루트/context surface이지 TCC grant나 OS sandbox가 아니다. 특히 declared bridge의
`bypassPermissions`는 Read/Edit/Bash를 포함한 Claude permission layer를 건너뛰므로,
Workspace-only가 effective tool authorization을 좁히거나 임의 protected-path Bash의 TCC 요청을
차단한다고 해석하지 않는다. C는 Codex가 의도적으로 다른 앱 container에 접근할 때의 AppData
prompt를 해결하지 않으며 기존 TCC decision을 제거하지도 않는다. 보호 폴더를 명시 추가한 뒤에도
해당 macOS service의 first-use prompt 위험은 남으므로 실제 read에는 outer deadline을 둔다.
managed PPPC는 지원되는 선언적 대안으로 평가했으나, 새 MDM trust boundary를 이번 Goal에
추가하지 않는 운영자 선택에 따라 도입하지 않았다.

## C: Workspace-only와 보호 폴더 opt-in

`permissions.additionalDirectories`에는 `~/Workspace`만 영구 유지한다. 보호 폴더가 필요한
경우 다음 중 하나로 해당 세션에만 추가한다.

- 실행 중인 Claude/Remote Control 세션: `/add-dir ~/Desktop`처럼 `/add-dir`를 사용한다.
- 새 direct CLI session: `claude --add-dir ~/Desktop`처럼 시작한다.
- 선언된 `claude-rc` wrapper는 `--add-dir`를 전달하지 않으므로 launcher 설정에 임의로 넣지
  않는다. Remote Control에서는 활성 세션의 `/add-dir` 경로를 사용한다.

`CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD=1`은 `/add-dir`/`--add-dir`로 추가한 작업
루트의 `CLAUDE.md`와 rules를 로드하는 대체 DX를 보존한다. settings의 persistent
`additionalDirectories`는 file access만 추가하고 해당 configuration을 로드하지 않는다.
Desktop/Documents/Downloads를 다시 영구 허용하는 rollback은 settings의 exact list를 복원한
뒤 `nrs`와 실제 launcher matrix를 다시 실행한다. 어느 방향도 macOS TCC state를 선언하거나
rollback하지 않는다.

### `/add-dir` deadline 경계와 원격 복구

`/add-dir`/`--add-dir` 처리와 그 과정의 `CLAUDE.md`/rules 자동 로드에는 repo가 설정하는
launcher-internal deadline이 없다. 예제의 GNU `timeout -k`는 Bash가 실행한 exact file-read
subprocess만 제한한다. Claude/Codex native Read/tool execution에는 repo deadline이 없다.
`claude-rc-maint`의 start/restart/identity poll도 bridge
lifecycle deadline일 뿐 session command나 TCC decision의 deadline이 아니다.

보호 폴더가 필요한 원격 작업은 Mac 앞에 있을 때 실제 intended launcher lineage에서 먼저
opt-in하고 exact TCC prompt를 운영자가 resolve한 뒤 사용한다. Claude Remote Control 준비를
Ghostty/direct CLI 결과로 대신하지 않는다. 준비하지 못했다면 원격에서는 Workspace-only를
유지한다. 원격 `/add-dir`가 멈추면 Stop/abort는 best-effort이며 popup을 닫거나 bounded 종료를
증명하지 않는다. macOS periodic ensure는 죽은 bridge만 자동 복구하고 live version drift는
`deferred-restart-confirmation`으로 보존한다. 로컬 복귀 뒤 prompt를 resolve하고, 재시작이 꼭
필요하면 action-time confirmation을 받은 뒤
`managing-claude-rc` runbook대로 등록된 전체 drift 후보를 열거·재확인하고
`CLAUDE_RC_DRIFT_POLICY=confirmed`와 처음 확인한 exact path/version approval JSON으로
`claude-rc-maint ensure`를 한 번 실행한다. maint는 lifecycle lock 안에서 현재 전체 drift tuple과
approval을 다시 비교하고, 하나라도 달라지면 restart 전에 실패한다. 이 override는 단일 path가 아니라
모든 등록 인스턴스를 순회한다. tombstone은 exact worktree에서
`claude remote-control --session-id <cse_...>`로 복구한다.
세션을 포기할 때만 환경 상세에서 종료해 capacity를 해제하고 silent routing을 확인한다.

| 단계 | deadline 책임 |
|---|---|
| Claude `/add-dir` + auto-load | Claude runtime; 현재 repo-managed deadline 없음 |
| Claude/Codex Bash file-read subprocess | caller가 exact child에 GNU `timeout -k` 적용 |
| Claude/Codex native Read/tool | 현재 repo-managed deadline 없음 |
| Shottr/`nrs` defaults access | defaults helper의 code-level deadline + circuit breaker |

caller timeout은 표시된 privacy popup을 dismiss하거나 allow/deny 결정을 증명하지 않는다.

최종 no-grant matrix는 C의 성공/한계를 다음처럼 확인했다. exact 시각, process identity와
원시 TCC log는 로컬 검증 중에만 보관하고 repo에는 aggregate 결과만 기록한다.

| Launcher | repo read | Desktop fixture | prompt | 해석 |
|---|---|---|---:|---|
| Claude Remote Control actual child | deadline 안 exit 0 | immediate exit 2 | 0 | 실제 bridge→CLI→Bash lineage에서 protected-folder access가 즉시 deny |
| Codex App actual child | deadline 안 exit 0 | immediate exit 2 | 0 | app restart 뒤 새 bundled child에서도 remembered deny 유지 |
| Ghostty direct child | deadline 안 exit 0 | deadline 안 exit 0 | 0 | D의 FDA 적용; remote 증거 아님 |

따라서 C의 성공은 일반 Workspace 작업 지속과 GNU timeout으로 감싼 명시적 Bash file-read
subprocess의 bounded 종료이지 `/add-dir`/auto-load, native Read/tool, protected fixture 접근 성공이나 prompt
제거가 아니다. 최종 remembered-deny cell에서 Claude는 즉시 exit 2였고 exact probe window에 새
auth request가 없었다. Codex도 즉시 exit 2였으며 같은 구간에
`kTCCServiceSystemPolicyDesktopFolder`/`kTCCServiceSystemPolicyAllFiles`가 관측됐지만 새
`AUTHREQ_PROMPTING`은 없었다. 이 결과를 fresh install, reset 또는 app update 뒤의 first-use prompt
제거로 일반화하지 않으며, 매 probe의 exit와 같은 구간 tccd event 및 최종 System Settings state를
함께 확인한다.

## Identity 확인

bundle app은 bundle ID와 designated requirement를, non-bundled binary는 실제 path와
designated requirement를 함께 기록한다.

```bash
codesign -dr - /Applications/ChatGPT.app
codesign -dr - /Applications/Ghostty.app
codesign -dr - "$(command -v claude)"
```

현재 identity는 실행 시점에 `codesign`으로 다시 확인한다. repo에는 공개 bundle ID와 역할만
고정하고 Team ID/designated requirement의 실측값은 복사하지 않는다.

| App | Bundle ID | 용도 |
|---|---|---|
| ChatGPT/Codex | `com.openai.codex` | Codex App remote |
| Ghostty | `com.mitchellh.ghostty` | direct terminal only |
| Claude Code binary | `com.anthropic.claude-code` | accessing client; 실제 responsible는 로그로 별도 확인 |

Claude Remote Control의 Bash tool은 Nix bash를 사용하지만, interactive shell의
`command -v bash`는 launchd maint 또는 tccd가 기록한 responsible binary와 다른
`bash-interactive` store path를 가리킬 수 있다. Nix store path와 ad-hoc CDHash는
rebuild/update 때도 달라질 수 있으므로 PATH나 signed Claude binary identity로 대신 추정하지
않는다.

probe 시작/종료 시각을 기록하고 실제 read는 별도의 GNU `timeout -k`로 제한한다. probe가
끝난 뒤 같은 구간을 유한하게 조회해 `responsible`/`accessing`, service,
`AUTHREQ_PROMPTING`을 확인한다.

```bash
START='<probe-start-local>'
END='<probe-end-local>'
nix develop --command bash -lc '
  set -o pipefail
  timeout -k 5s 30s /usr/bin/log show --start "$1" --end "$2" \
    --style compact --info --debug \
    --predicate '\''process == "tccd" OR process == "sandboxd"'\'' \
    | rg '\''AUTHREQ|responsible|accessing|SystemPolicy'\''
' bash "$START" "$END"
```

tccd event의 exact `responsible` `binary_path`를 복사해 그 경로 자체를 검사한다. 배포된 maint
interpreter는 attribution의 대체물이 아니라 교차검증 후보로만 사용한다.

```bash
RESPONSIBLE='/exact/binary_path/from/tccd-event'
test -x "$RESPONSIBLE"
codesign -dr - "$RESPONSIBLE"

PLIST="$HOME/Library/LaunchAgents/org.nix-community.home.claude-rc-ensure.plist"
MAINT="$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$PLIST")"
ACTION="$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:1' "$PLIST")"
case "$MAINT" in
  /nix/store/*/bin/claude-rc-maint) ;;
  *) printf 'unexpected maint path: %s\n' "$MAINT" >&2; exit 1 ;;
esac
[ "$ACTION" = "ensure" ] || {
  printf 'unexpected maint action: %s\n' "$ACTION" >&2
  exit 1
}
MAINT_INTERPRETER="$(sed -n '1s/^#!//p' "$MAINT")"
MAINT_INTERPRETER="${MAINT_INTERPRETER%% *}"
printf 'maint=%s\ninterpreter=%s\n' "$MAINT" "$MAINT_INTERPRETER"
codesign -dr - "$MAINT_INTERPRETER"
```

## Launcher별 actual E2E recipe

세 launcher는 한 번에 하나만 검증한다. 공통 payload는 exact launcher가 만든 child 안에서만
실행하며, repo의 고정 공개 파일 1개와 `umask 077`로 만든 보호 폴더 fixture 1개만 읽는다.
각 read는 devShell의 `timeout -k 2s 10s`로 감싸고 start/end, exit, elapsed를 기록한다. child의
PID/parent/executable 원문은 mode 0600 임시 기록으로만 확인하고 repo에는 aggregate만 남긴다.

| Launcher | 실제 진입점 | lineage 합격 조건 | 증거로 금지하는 대체물 |
|---|---|---|---|
| Claude Remote Control | 이미 pair된 휴대폰 Remote Control의 해당 repo session에서 Bash payload 실행 | transient Bash에서 위로 추적한 server의 cwd가 exact repo이고 argv가 `remote-control`; managed Claude executable과 trusted `flock`의 exact instance lock을 `claude-rc ls`, `ps`, `lsof`로 교차 확인 | 로컬 `claude -p`, direct CLI, Ghostty shell |
| Codex App remote | ChatGPT/Codex App의 실제 remote task가 만든 bundled child에서 payload 실행 | child에서 위로 추적한 app/helper가 `/Applications/ChatGPT.app` bundle 안에 있고 `codesign` bundle ID가 `com.openai.codex`; 새 child인지 restart 전 identity와 비교 | 일반 shell, Codex CLI, 앱과 무관한 터미널 child |
| Ghostty direct | 새 Ghostty tab/window의 direct shell에서 payload 실행 | shell의 parent chain이 codesigned Ghostty bundle로 이어지고 bundle ID가 `com.mitchellh.ghostty` | Claude/Codex remote 성공 증거 |

실행 순서는 다음과 같다.

1. launcher 진입 전에 repo path, fixture path와 probe start를 정하고 해당 launcher 외 다른 probe를
   중지한다.
2. actual child에서 lineage를 먼저 기록한 뒤 같은 child에서 repo read와 fixture read를 순서대로
   실행한다. lineage가 불명확하면 read 결과와 무관하게 그 cell은 실패다.
3. probe end 뒤 그 구간의 bounded tccd/sandboxd query로 service와 새
   `AUTHREQ_PROMPTING` 수를 대조한다.
4. action-time confirmation을 받은 restart/reboot 뒤에는 새 child임을 확인하고 같은 cell을
   반복한다. 이전 child 결과를 재사용하지 않는다.
5. fixture, lineage 임시 기록과 probe process를 제거하고 System Settings에서 선택하지 않은
   grant가 남지 않았는지 읽기 전용으로 재확인한다.

## 수동 targeted / FDA 절차

1. 현재 System Settings 상태와 app/binary code identity를 읽기 전용으로 기록한다.
2. launcher를 하나만 실행하고 시작 시각을 기록한다.
3. `umask 077`로 보호 폴더에 고정 문자열 하나만 담은 fixture를 만든다. 기존 파일을
   enumerate/read하지 않는다.
4. devShell의 GNU `timeout -k`로 repo read와 fixture read에 outer deadline을 둔다.
5. prompt가 필요하면 action-time confirmation 뒤 운영자가 정확한 System Settings toggle만
   변경한다. Files & Folders UI는 일반 앱/바이너리를 임의로 사전 추가하는 surface가 아니다.
6. 같은 launcher matrix를 반복해 exit, elapsed, prompt count, service를 기록한다.
7. 별도 확인 뒤 launcher restart, 필요한 경우 reboot 후 반복한다.
8. fixture와 임시 프로세스를 정리하고 선택하지 않은 시험 권한이 남지 않았는지 확인한다.

`nrs` 같은 정상 activation도 sandbox app preference를 `defaults`로 읽거나 쓰면 responsible
app의 `SystemPolicyAppData` prompt를 만들 수 있다. 이런 호출은 권한 성공 증거로 간주하지
않고 outer deadline과 kill-after를 적용해 원격 activation이 무기한 대기하지 않게 한다.
deadline은 caller만 끝내며 이미 표시된 macOS privacy popup을 dismiss하지 않는다. prompt를
승인하지 않은 상태에서 Codex App remote child가 별도의 harmless repo fixture를 계속 처리하는지
확인해야 “원격 세션이 계속된다”고 판정한다.

System Settings 경로:

- targeted: Privacy & Security > Files & Folders
- FDA: Privacy & Security > Full Disk Access

rollback은 같은 UI에서 targeted toggle을 끄거나 FDA entry를 끄고 제거한다. 권한 제거,
앱 종료/재실행, reboot도 각각 직전에 확인을 받는다. grant가 같은 identity의 app restart 뒤에도
지속한다고 추정하지 않는다. rollback 뒤에는 harmless fixture만으로 effective state를 다시
확인한다.

UI가 같은 bundle의 App Data와 folder state를 모호하게 표시할 때는 action-time confirmation 뒤
정확히 식별한 service와 bundle만 `tccutil reset <service> <bundle-id>`로 제거할 수 있다. 이는
grant 명령이 아니며 다음 접근을 다시 prompt/deny 상태로 되돌린다. `reset All`, bundle을 생략한
service-wide reset, TCC DB 직접 수정은 사용하지 않는다. 실행 뒤 matching tccd Delete event와
System Settings를 다시 읽어 선택하지 않은 grant가 남지 않았는지 확인한다. 실제로 reset한
service 목록과 시각은 로컬 작업 기록에만 둔다.

## Managed PPPC

Apple의 `com.apple.TCC.configuration-profile-policy` payload는 다음 서비스를 `Allow`할 수
있다.

| TCC service | 범위 |
|---|---|
| `SystemPolicyDesktopFolder` | Desktop |
| `SystemPolicyDocumentsFolder` | Documents |
| `SystemPolicyDownloadsFolder` | Downloads |
| `SystemPolicyAppData` | 다른 앱 data |
| `SystemPolicyAllFiles` | Full Disk Access |

PPPC는 `Allow manual install = N/A`이고 user-approved MDM이 필요하다. 일반 Device
Enrollment이면 충분하며 Automated Device Enrollment는 필수가 아니다. 최소 profile
배포 MDM은 enrollment payload를 inspection + install/removal인 `AccessRights=3`으로 제한할
수 있지만, enrollment 자체가 macOS supervision과 APNs/TLS/certificate 운영을 추가한다.

PPPC identity 규칙:

- app bundle: `IdentifierType=bundleID`, bundle ID, `CodeRequirement`
- non-bundled binary: `IdentifierType=path`, exact path, `CodeRequirement`
- `Allowed=true` 또는 `Authorization=Allow` 중 하나만 사용
- 여러 payload가 충돌하면 더 제한적인 decision이 우선

MDM을 사용해도 versioned Nix bash drift는 사라지지 않는다. Nix update 시 새 exact path와
CodeRequirement로 payload를 재생성하고 MDM acknowledgment 뒤 실제 launcher matrix를 다시
통과해야 한다. `nrs` 성공만으로 PPPC 적용을 선언하지 않는다.

rollback은 MDM이 PPPC profile을 제거하고 acknowledgment를 받은 뒤 fixture matrix로
effective state를 확인한다. enrollment 제거는 해당 enrollment가 설치한 profile을 함께
제거하지만, 기존 user decision의 최종 상태는 추측하지 않고 다시 측정한다.

## Update / reboot 재검증 조건

다음 중 하나라도 바뀌면 identity와 전체 matrix를 다시 확인한다.

- Claude/Codex/Ghostty app 또는 CLI update
- Nix launcher executable identity
- launcher argv, parentage, launchd/SMAppService wiring
- macOS major update 또는 PPPC schema 변경
- MDM enrollment/profile/APNs certificate 변경

재검증은 위 [Launcher별 actual E2E recipe](#launcher별-actual-e2e-recipe)의 진입점과 lineage
조건을 그대로 사용한다. generic shell이나 이전 child의 결과로 대체하지 않는다.

responsible identity가 restart/reboot 전후 달라지거나 Claude/Codex 중 한 launcher만 통과하면
전체 remote 정책 성공으로 판정하지 않는다.

## 공식 근거

- [Privacy Preferences Policy Control](https://developer.apple.com/documentation/devicemanagement/privacypreferencespolicycontrol)
- [PPPC services](https://developer.apple.com/documentation/devicemanagement/privacypreferencespolicycontrol/services-data.dictionary)
- [PPPC identity](https://developer.apple.com/documentation/devicemanagement/privacypreferencespolicycontrol/services-data.dictionary/identity)
- [Device Enrollment](https://support.apple.com/guide/deployment/depd1c27dfe6/web)
- [MDM AccessRights](https://developer.apple.com/documentation/devicemanagement/mdm)
- [Controlling app access to files](https://support.apple.com/guide/security/controlling-app-access-to-files-secddd1d86a6/web)
- [Claude working directories](https://code.claude.com/docs/en/permissions#working-directories)
- [Claude bypassPermissions mode](https://code.claude.com/docs/en/permission-modes#skip-all-checks-with-bypasspermissions-mode)
