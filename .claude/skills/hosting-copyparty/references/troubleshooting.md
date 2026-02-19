# Copyparty 트러블슈팅

## 1. 컨테이너 시작 실패 (일반)

**증상**: `podman-copyparty` 서비스가 시작되지 않음

**진단**:
```bash
systemctl status podman-copyparty          # ConditionPathExists 실패 여부 확인
systemctl status copyparty-config          # 설정 생성 서비스 상태
journalctl -u copyparty-config             # 설정 생성 로그
ls -la /var/lib/docker-data/copyparty/config/copyparty.conf  # 설정 파일 존재 확인
```

**해결**:
- `ConditionPathExists` 실패 시: `copyparty-config` 서비스가 먼저 성공해야 함
- 설정 생성 실패 시: agenix 시크릿 복호화 확인 (`ls -la /run/agenix/copyparty-password`)
- `sudo systemctl restart copyparty-config && sudo systemctl restart podman-copyparty`

## 2. 로그인 실패

**증상**: 웹 UI에서 greenhead 계정으로 로그인 불가

**진단**:
```bash
sudo cat /run/agenix/copyparty-password              # 복호화된 비밀번호 확인
sudo cat /var/lib/docker-data/copyparty/config/copyparty.conf  # 설정 파일 내 계정 확인
sudo cat /run/agenix/copyparty-password | xxd         # 바이트 레벨 확인 (이스케이프 문자)
```

**해결**:
- 비밀번호에 이스케이프 문자(`\`)가 포함되면 `agenix -e secrets/copyparty-password.age`로 재입력
- 설정 파일 재생성: `sudo systemctl restart copyparty-config && sudo systemctl restart podman-copyparty`

## 3. HTTPS 접근 실패 (CORS 403)

**증상**: `https://copyparty.greenhead.dev` 접근 시 `rejected by cors-check` 에러

**진단**:
```bash
sudo podman logs --tail 20 copyparty         # CORS 에러 로그 확인
sudo podman exec copyparty cat /cfg/config.conf  # 설정 확인
curl -I http://127.0.0.1:3923                # localhost 직접 확인
curl -sI -H 'Origin: https://copyparty.greenhead.dev' https://copyparty.greenhead.dev/  # CORS 헤더 확인
```

**해결**:
- `[global]` 섹션에 `rproxy: 1` + `xff-src: 10.88.0.0/16` (constants.network.podmanSubnet) 확인
- `rproxy: 1`만으로는 부족 — Podman 브릿지 네트워크 게이트웨이를 `xff-src`로 신뢰해야 함
- 설정 변경 후 컨테이너 재시작 필수: `sudo systemctl restart podman-copyparty`

## 4. 비밀번호 변경

**절차**:
```bash
# 1. 시크릿 파일 재암호화
agenix -e secrets/copyparty-password.age
# 에디터에서 새 비밀번호 입력 후 저장

# 2. 빌드 적용
nrs

# 3. 설정 재생성 + 컨테이너 재시작 (nrs가 처리하지만 수동 필요시)
sudo systemctl restart copyparty-config
sudo systemctl restart podman-copyparty
```

## 5. 설정 파일 내용 확인

**진단**: 설정 파일이 올바르게 생성되었는지 확인

```bash
# 설정 파일 전체 확인
sudo cat /var/lib/docker-data/copyparty/config/copyparty.conf

# 공백/탭 등 whitespace 문제 확인
sudo cat /var/lib/docker-data/copyparty/config/copyparty.conf | cat -A
```

**정상 설정 예시**:
```ini
[global]
  hist: /cfg/hists
  th-maxage: 7776000
  no-crt
  rproxy: 1
  xff-src: 10.88.0.0/16  # constants.network.podmanSubnet

[accounts]
  greenhead: <PASSWORD>

[/]
  /data
  accs:
    rwda: greenhead
```

## 6. "multiple filesystem-paths" 에러

**증상**: 컨테이너 로그에 다음 에러 출력 후 즉시 종료
```
CRIT: multiple filesystem-paths mounted at [/immich]:
  [/data/immich]
  [/data/immich]
```

**원인**:
Copyparty 설정에서 루트 볼륨 `[/]` -> `/data`와 서브경로 볼륨 `[/immich]` -> `/data/immich`을 동시에 선언.
루트 볼륨이 이미 `/data/immich`을 `/immich`으로 서빙하므로, `[/immich]` 별도 선언 시 동일 가상 경로에
두 개의 파일시스템 경로가 매핑되어 충돌.

**해결**:
- 경로별 읽기 전용 ACL 분리 불가 - Copyparty 구조적 제약
- 단일 루트 볼륨 `[/]` -> `/data`만 사용 (rwda 권한)
- Immich/백업 데이터 보호는 사용자 주의에 의존

**교훈**:
Copyparty에서 하위 경로에 다른 ACL을 적용하려면 루트 볼륨과 분리된 가상 경로를 사용해야 한다.
예: `[/photos]` -> `/data/immich` (루트 `/`에 `/data` 마운트하지 않는 경우에만 가능).
단, 이 경우 HDD 전체를 단일 루트로 탐색할 수 없어 사용성이 떨어진다.

## 7. initcfg 루트 볼륨 충돌

**증상**: 컨테이너 로그에 다음 에러 출력 후 즉시 종료
```
CRIT: multiple filesystem-paths mounted at [/]:
  [/data]
  [/data]
```

**원인**:
`copyparty/ac` 이미지의 ENTRYPOINT가 `python3 -m copyparty -c /z/initcfg`로 설정됨.
initcfg 내용:
```ini
[global]
  chdir: /w
  no-crt
% /cfg
```
`% /cfg` 라인이 컨테이너의 `/cfg` 디렉토리를 루트 `/`에 볼륨 마운트.
우리 설정의 `[/]` -> `/data`와 충돌하여 동일 가상 경로에 두 개 매핑 발생.

`-c` 플래그는 "나중 설정이 이전을 오버라이드"하지만, 볼륨 마운트는 오버라이드되지 않고 누적됨.

**해결**:
```nix
# entrypoint 오버라이드로 initcfg 완전 무시
extraOptions = [ "--entrypoint=python3" ... ];
cmd = [ "-m" "copyparty" "-c" "/cfg/config.conf" ];
```

- `--entrypoint=python3`로 이미지 기본 ENTRYPOINT를 오버라이드
- `cmd`에 `-m copyparty`부터 직접 전달
- initcfg에 있던 `no-crt` 설정을 우리 config `[global]` 섹션에 직접 추가
- `chdir: /w`는 불필요 (기본 동작에 영향 없음)

**교훈**:
Copyparty Docker 이미지의 `-c` 플래그는 설정값(global, accounts)은 오버라이드하지만,
볼륨 매핑(`%`, `[/path]`)은 병합(누적)된다. 커스텀 볼륨을 사용할 때는
반드시 initcfg를 건너뛰어야 한다.

## 8. NixOS 배포 절차 주의사항

**MiniPC에 배포하려면**:
1. 로컬에서 코드 변경 → git commit → git push
2. `ssh minipc` → `cd ~/Workspace/nixos-config && git pull`
3. `nrs` (MiniPC의 nrs.sh = `sudo nixos-rebuild switch --flake .`)

**흔한 실수**:
- 로컬 Mac에서 `nrs` 실행 → darwin-rebuild만 됨, MiniPC에는 적용 안 됨
- git push 없이 MiniPC에서 `git pull` → 변경사항 없음
- flake 기반이라 **git에 추가되지 않은 파일은 빌드에 포함되지 않음**

## 9. 컨테이너 재시작 후 403 에러 (세션 유실)

**증상**: 컨테이너 재시작 후 로그인 상태가 풀리고 "오류 403: 접근 거부됨" 발생

**원인**:
CopyParty는 세션 DB(`sessions.db`)와 인증 salt 파일들을 컨테이너 내부 `/cfg/copyparty/`에 저장.
이 경로가 볼륨 마운트되지 않으면 컨테이너 재시작 시 모든 세션 데이터 유실.
salt 파일 유실 시 기존 세션 쿠키가 전부 무효화되어 재로그인 필요.

**진단**:
```bash
# 세션 디렉토리 볼륨 마운트 확인
sudo podman inspect copyparty --format '{{range .Mounts}}{{.Destination}} {{end}}' | grep copyparty

# 호스트 세션 디렉토리 확인
sudo ls -la /var/lib/docker-data/copyparty/sessions/
# 예상: sessions.db, ah-salt.txt, dk-salt.txt, fk-salt.txt, iphash

# 컨테이너 종료 코드 확인 (137 = OOM kill)
sudo podman inspect copyparty --format '{{.State.ExitCode}}'
```

**해결**:
- `copyparty.nix`에서 `${dockerData}/copyparty/sessions:/cfg/copyparty` 볼륨 마운트 확인
- 세션 초기화 필요 시: `sudo rm /var/lib/docker-data/copyparty/sessions/*` 후 컨테이너 재시작
