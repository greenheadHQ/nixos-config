# 트러블슈팅

아래 `age` 명령은 `nix-shell -p age` 환경에서 실행 (devShell에 미포함).

## agenix -e의 /dev/stdin 에러

> **발생 시점**: 2026-01-27
> **해결**: age CLI pipe 우회

**증상**: Claude Code Bash 환경에서 `agenix -e` 실행 시 실패.

```
cp: cannot open '/dev/stdin' for reading: No such device or address
pushover-claude-stop.age wasn't created.
```

`EDITOR="cp $TMPFILE"` 스크립트 우회도 동일하게 실패.

**원인**: `agenix -e`는 내부적으로 `/dev/stdin`을 사용하는 interactive 모델이다. Claude Code의 Bash 환경은 non-interactive라 `/dev/stdin`이 없다.

| 방식 | Interactive 터미널 | Claude Code (non-interactive) |
|------|:--:|:--:|
| `agenix -e` | O | X (`/dev/stdin` 없음) |
| `age` CLI (pipe) | O | O |

**해결**: `age` CLI를 직접 호출하여 pipe 기반으로 암호화.

```bash
# secrets/secrets.nix에서 공개키 확인 후 모든 recipient 지정
printf 'KEY=value\n' | \
  nix-shell -p age --run \
  'age -r "ssh-ed25519 <key1>" -r "ssh-ed25519 <key2>" -o secrets/<name>.age'
```

---

## 복호화 실패

**증상**: `age -d`로 복호화 시 에러.

```
Error: no identity matched any of the recipients
```

**원인**:

1. **SSH 키 불일치**: 현재 머신의 SSH 키가 암호화 시 recipient에 포함되지 않음
2. **identity path 오류**: 기본 경로(`~/.ssh/id_ed25519`)가 아닌 경우

**진단**:

```bash
# 현재 머신의 공개키 확인
cat ~/.ssh/id_ed25519.pub

# secrets/secrets.nix의 allHosts에 포함되어 있는지 확인
```

**해결**: identity path를 명시적으로 지정하여 복호화.

```bash
nix-shell -p age --run 'age -d -i ~/.ssh/id_ed25519 secrets/<name>.age'
```

키가 포함되어 있지 않다면 `secrets/secrets.nix`에 공개키 추가 후 `agenix -r`로 재암호화 필요.

---

## 재암호화 실패

**증상**: `secrets/secrets.nix`에서 publicKeys를 변경했는데, 새 호스트에서 복호화 실패.

**원인**: publicKeys 변경 후 `agenix -r` (재암호화) 미실행. `.age` 파일은 변경 시점의 recipient 목록으로 암호화되어 있으므로, publicKeys를 변경한 후 반드시 재암호화해야 한다.

**해결**:

```bash
# 모든 .age 파일을 secrets.nix의 최신 publicKeys로 재암호화
nix run github:ryantm/agenix -- -r
```

**호스트 키 변경 시**: 해당 호스트의 SSH 키가 재생성된 경우, `secrets/secrets.nix`에서 공개키를 업데이트한 후 재암호화.

---

## 배포 후 파일 미생성

**증상**: `nrs` 실행 후 secret 파일이 기대 경로에 없음 (예: `~/.config/pushover/` 아래에 파일 없음).

**원인**:

1. `modules/shared/programs/secrets/default.nix`에 배포 설정이 누락됨
2. Home Manager agenix 서비스가 정상 작동하지 않음
3. `.age` 파일이 아직 생성되지 않음

**진단**:

```bash
# 배포된 파일 확인
ls -la ~/.config/pushover/

# Home Manager 서비스 상태 확인 (NixOS)
systemctl --user status agenix

# .age 파일 존재 여부
ls -la secrets/*.age
```

**해결**:

1. `modules/shared/programs/secrets/default.nix`에 배포 설정 추가
2. `nrs`로 재빌드
3. 배포 경로에서 파일 존재 확인
