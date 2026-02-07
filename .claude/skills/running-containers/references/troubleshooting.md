# 트러블슈팅

## 컨테이너 관련

### immich OOM으로 인한 시스템 불안정

**날짜**: 2026-01-21

**증상**: miniPC에 Tailscale SSH 접속 불가, 시스템 응답 없음. 모니터 확인 시 OOM 로그 대량 출력:

```
Memory cgroup out of memory: Killed process 93379 (immich) total-vm:28522012kB
Memory cgroup out of memory: Killed process 94003 (immich) total-vm:28810952kB
...
```

**원인**:

immich-ml 컨테이너가 **OpenVINO 버전** (`ghcr.io/immich-app/immich-machine-learning:release-openvino`)을 사용 중이었음. OpenVINO ML 모델은 메모리를 많이 사용하여 4GB 제한을 초과 → OOM Killer 작동 → 컨테이너 재시작 → 다시 OOM → **무한 루프**.

| 컨테이너 | 메모리 제한 | 실제 요구량 (OpenVINO) |
|----------|-----------|---------------------|
| immich-ml | 4GB | 6GB+ |
| immich-server | 4GB | 적정 |

이 과정에서 tailscaled 등 다른 서비스도 영향을 받아 시스템 전체가 불안정해짐.

**해결**:

1. 즉시 조치 (OOM 루프 탈출):
```bash
sudo systemctl stop podman-immich-server podman-immich-ml podman-immich-postgres podman-immich-redis
sudo systemctl restart tailscaled
```

2. 영구 해결 - OpenVINO 대신 일반 이미지 사용:
```nix
# modules/nixos/programs/docker/immich.nix
virtualisation.oci-containers.containers.immich-ml = {
  image = "ghcr.io/immich-app/immich-machine-learning:release";  # openvino 제거
  extraOptions = [
    "--memory=2g"      # 4g에서 2g로 감소
    "--memory-swap=3g"
    # GPU 관련 옵션 제거
  ];
};
```

**변경 전후 비교**:

| 항목 | 변경 전 (OpenVINO) | 변경 후 (CPU) |
|------|-------------------|--------------|
| 이미지 | `release-openvino` | `release` |
| 메모리 | 4GB | 2GB |
| GPU | `/dev/dri` 사용 | 미사용 |
| ML 속도 | 빠름 | 느림 (허용 가능) |
| 안정성 | OOM 위험 | 안정적 |

**적용 상태**: 완료 (커밋: `eb65449`, 2026-01-21)

**교훈**:

- Intel N100 같은 저전력 시스템에서 OpenVINO는 메모리 부담이 큼
- immich ML 작업은 사진 업로드 시에만 발생하므로 속도 저하 체감이 적음
- 컨테이너 메모리 제한 설정 시 실제 사용량 모니터링 필요:
```bash
sudo podman stats --no-stream
```

### Tailscale IP 바인딩 서비스 부팅 순서 문제

**날짜**: 2026-01-21

**증상**: 부팅 후 immich, uptime-kuma 등 Tailscale IP에 바인딩하는 서비스가 실패:

```
Error: failed to expose ports via rootlessport: cannot expose privileged port 2283,
you can add 'net.ipv4.ip_unprivileged_port_start=2283' to /etc/sysctl.conf
(currently snip), or choose a larger port number (>= 1024): listen tcp 100.79.80.95:2283:
bind: cannot assign requested address
```

**원인**:

`tailscaled.service`가 시작되었다고 해서 Tailscale IP가 바로 사용 가능한 것은 아님:

| 단계 | 설명 |
|------|------|
| 1. tailscaled 시작 | 데몬 프로세스 실행 |
| 2. 네트워크 인증 | Tailscale 서버와 통신 |
| 3. IP 할당 | 100.x.x.x IP 주소 할당 (수 초~수십 초) |
| 4. 인터페이스 준비 | tailscale0 인터페이스에서 IP 사용 가능 |

`after = [ "tailscaled.service" ]`만으로는 1단계만 기다리고 4단계를 기다리지 않음.

**해결**:

`ExecStartPre`로 Tailscale IP 할당 완료까지 대기하는 로직 추가:

```nix
# 예시: create-immich-network 서비스
systemd.services.create-immich-network = {
  after = [
    "podman.socket"
    "network-online.target"
    "tailscaled.service"
  ];
  wants = [
    "podman.socket"
    "tailscaled.service"
    "network-online.target"
  ];
  serviceConfig = {
    Type = "oneshot";
    RemainAfterExit = true;
    # Tailscale IP 할당 완료까지 대기 (최대 60초)
    ExecStartPre = "${pkgs.bash}/bin/bash -c 'for i in $(seq 1 60); do ${pkgs.tailscale}/bin/tailscale ip -4 2>/dev/null | grep -q \"^100\\.\" && exit 0; sleep 1; done; echo \"Tailscale IP not ready after 60s\" >&2; exit 1'";
    ExecStart = "${pkgs.podman}/bin/podman network create immich-network --ignore";
  };
};
```

**적용 대상**:
- `immich.nix`: create-immich-network 서비스
- `uptime-kuma.nix`: podman-uptime-kuma 서비스
**검증**:

```bash
# 재부팅 후 서비스 상태 확인
systemctl status create-immich-network
systemctl status podman-immich-server
systemctl status podman-uptime-kuma

# 부팅 순서 로그 확인
journalctl -b -u tailscaled -u create-immich-network -u podman-immich-server --no-pager | head -50

# 포트 바인딩 확인
curl -I http://100.79.80.95:2283  # immich
curl -I http://100.79.80.95:3002  # uptime-kuma
```

**적용 상태**: 완료 (커밋: `4153e1d`, 2026-01-21)

**교훈**:
- `after = [ "xxx.service" ]`는 서비스 시작만 보장, 완전히 준비됨을 보장하지 않음
- Tailscale처럼 네트워크 의존 서비스는 실제 리소스 가용성을 확인하는 로직 필요

**향후 개선 사항** (기술 부채):

| 항목 | 현재 상태 | 개선 방향 |
|------|----------|----------|
| tailscaleIP 하드코딩 | 3개 파일에 중복 정의 (`immich.nix`, `uptime-kuma.nix`, `default.nix`) | 단일 소스로 추출 (let 바인딩 또는 별도 모듈) |
| Tailscale 대기 로직 중복 | 3개 파일에 동일한 bash 스크립트 | 공통 스크립트 또는 함수로 추출 |
| immich DB 비밀번호 | `immich.nix:51`에 평문 하드코딩 | sops-nix 등 secrets 관리로 이동 |

### Scriptable 공유 시트에서 스크립트 실행 시 무반응

**날짜**: 2026-02-03

**증상**: Scriptable 스크립트를 사진 앱 → 공유 → Scriptable로 실행하면 아무 알림이나 팝업이 표시되지 않음. 앱 내에서 직접 실행하면 정상 작동.

**원인**:

Scriptable 스크립트 설정에서 **Share Sheet Inputs**의 **Images**만 체크한 경우 발생할 수 있음.

**해결**:

1. Scriptable 앱에서 스크립트 편집 화면 열기
2. 우측 하단 설정 아이콘 (⚙️) 탭
3. **Share Sheet Inputs** 섹션에서 다른 항목들(Text, URLs, File URLs)도 체크
4. 저장 후 다시 테스트

**교훈**:
- Share Sheet 동작은 체크된 입력 타입 조합에 따라 달라질 수 있음
- 문제 발생 시 모든 항목을 체크해보는 것이 디버깅에 도움됨

---

### Claude Code Read 도구 이미지 처리 실패

**날짜**: 2026-02-03

**증상**: Immich에 업로드된 이미지를 Claude Code Read 도구로 읽으려고 할 때 에러 발생:

```
API Error: 400
{"type":"error","error":{"type":"invalid_request_error","message":"Could not process image"}}
```

**원인**:

| 이미지 유형 | 크기 | 결과 |
|------------|------|------|
| 테스트용 1x1 픽셀 PNG | 69 bytes | ❌ 에러 |
| 실제 스크린샷 | 128KB+ | ✅ 성공 |

Claude API는 너무 작은 이미지(1x1 픽셀 등)를 처리할 수 없습니다. 이것은 의미 있는 컨텐츠가 없는 이미지에 대한 API 제한입니다.

**해결**:

실제 사용 시에는 스크린샷이나 사진 등 의미 있는 크기의 이미지를 업로드하므로 문제없습니다. 테스트 시에만 주의하면 됩니다.

**검증**:

```bash
# 이미지 크기 확인
file /path/to/image.png
# 정상: PNG image data, 1290 x 1012, ...
# 문제: PNG image data, 1 x 1, ...
```

**교훈**:
- API 테스트 시 실제 이미지 파일 사용 권장
- 최소 이미지 크기 제한이 존재함을 인지

---

### Redis RDB 저장 실패 (Permission denied)

**날짜**: 2026-01-23

**증상**:

1. Redis 로그에서 Permission denied 에러:
```
Failed opening the temp RDB file temp-*.rdb (in server root dir /data)
for saving: Permission denied
```

2. Immich 서버 로그에서 MISCONF 에러:
```
ReplyError: MISCONF Redis is configured to save RDB snapshots, but it's
currently unable to persist to disk. Commands that may modify the data set
are disabled, because this instance is configured to report errors during
writes if RDB snapshotting fails (stop-writes-on-bgsave-error option).
```

3. Immich 웹 UI에서 Job 실행 실패:
   - "메타데이터 갱신", "썸네일 재생성" 등 버튼 클릭 시 500 에러
   - 에러 메시지: "Failed to run asset jobs (Immich Server Error)"

**원인**:

| 항목 | 설정값 | 문제 |
|------|--------|------|
| 디렉토리 소유자 | root:root (755) | Redis 사용자가 쓰기 불가 |
| Redis 실행 사용자 | UID 999, GID 1000 | 디렉토리에 쓰기 권한 없음 |
| tmpfiles.rules | `0755 root root` | 잘못된 주석 "Redis는 root로 충분" |
| stop-writes-on-bgsave-error | yes (기본값) | RDB 저장 실패 시 쓰기 차단 |

Redis의 `stop-writes-on-bgsave-error=yes` 옵션으로 인해, RDB 저장 실패 시 데이터 일관성 보호를 위해 **모든 쓰기 작업이 차단**됨. 이로 인해 Immich의 Job Queue 추가가 실패하여 웹 UI의 모든 Job 관련 기능이 작동하지 않음.

**해결**:

Redis 볼륨 마운트 완전 제거 (공식 Immich 설정과 동일):

1. `immich.nix`에서 tmpfiles.rules의 redis 디렉토리 제거
2. `immich.nix`에서 Redis 컨테이너의 volumes 제거

```nix
# 삭제할 라인들:
"d ${dockerDataPath}/immich/redis 0755 root root -"
volumes = [ "${dockerDataPath}/immich/redis:/data" ];
```

**이유**:

- Redis는 Immich에서 Job Queue/캐싱 용도로만 사용 (영속성 불필요)
- 공식 Immich docker-compose에서도 Redis 볼륨 없음
- 원본 사진/동영상, PostgreSQL 데이터는 영향 없음
- Job Queue 손실 시 웹 UI에서 재생성 버튼으로 복구 가능

**적용 상태**: 완료 (커밋: `8840d14`, 2026-01-23)

**검증**:

```bash
# Redis 쓰기 테스트
sudo podman exec immich-redis redis-cli SET test "hello"
# 예상: OK (이전에는 MISCONF 에러)

# Immich 웹 UI에서 "메타데이터 갱신" 테스트
# 예상: 성공 (이전에는 500 에러)
```

**교훈**:

- 컨테이너 볼륨 권한 설정 시 컨테이너 내부 실행 사용자 UID 확인 필수
- 공식 설정을 참고하여 불필요한 영속성 설정 제거 검토
- 주석이 실제 동작과 일치하는지 검증 필요
- `stop-writes-on-bgsave-error` 옵션으로 인해 RDB 실패가 전체 쓰기 차단으로 이어질 수 있음

---

## NixOS systemd 설정

### ConditionPathExists가 무시되는 문제

**날짜**: 2026-02-04

**증상**: systemd 로그에서 경고 메시지:

```
Unknown key 'ConditionPathExists' in section [Service], ignoring.
```

**원인**:

`ConditionPathExists`를 `serviceConfig`에 넣었으나, 이 옵션은 `[Unit]` 섹션에 속함.

```nix
# 잘못된 설정
serviceConfig = {
  ConditionPathExists = [ ... ];  # ❌ [Service] 섹션으로 생성됨
};
```

**해결**:

`unitConfig`에 설정:

```nix
# 올바른 설정
unitConfig = {
  ConditionPathExists = [
    "/run/agenix/immich-api-key"
    "/run/agenix/pushover-immich"
  ];
};
```

**교훈**:

| NixOS 어트리뷰트 | systemd 섹션 | 용도 |
|-----------------|-------------|------|
| `unitConfig` | `[Unit]` | 조건, 의존성 등 |
| `serviceConfig` | `[Service]` | 실행 설정, 환경변수 등 |

---

### 환경변수에 공백이 있으면 분리되는 문제

**날짜**: 2026-02-04

**증상**: systemd 로그에서 경고 메시지:

```
Invalid environment assignment, ignoring: Code
Invalid environment assignment, ignoring: Temp
```

환경변수 `ALBUM_NAME="Claude Code Temp"`가 "Claude", "Code", "Temp"로 분리됨.

**원인**:

`serviceConfig.Environment` 리스트 사용 시 공백 처리 문제:

```nix
# 잘못된 설정
serviceConfig.Environment = [
  "ALBUM_NAME=${cfg.albumName}"  # ❌ 공백이 분리됨
];
```

**해결**:

`environment` 어트리뷰트 셋 사용:

```nix
# 올바른 설정
environment = {
  ALBUM_NAME = cfg.albumName;  # ✅ NixOS가 자동으로 처리
};
```

**교훈**:

| 방식 | 공백 처리 | 권장 |
|------|----------|------|
| `serviceConfig.Environment` | 수동 이스케이프 필요 | ❌ |
| `environment` | 자동 처리 | ✅ |

---

### agenix 시크릿 파일 형식 주의

**날짜**: 2026-02-04

**증상**: API 호출 시 401 Unauthorized:

```
{"message":"Invalid API key","error":"Unauthorized","statusCode":401}
```

**원인**:

시크릿 파일이 `KEY=value` 형식으로 저장되어 있는데, `cat`으로 읽으면 전체 문자열이 됨:

```bash
# 파일 내용
IMMICH_API_KEY=<YOUR_KEY>...

# cat으로 읽으면
API_KEY="IMMICH_API_KEY=<YOUR_KEY>..."  # ❌ 전체가 API 키가 됨
```

**해결**:

`source`로 로드 후 변수 사용:

```bash
# 올바른 방식
source "$API_KEY_FILE"
API_KEY="$IMMICH_API_KEY"  # ✅ 실제 값만 사용
```

**교훈**:

| 파일 형식 | 읽기 방식 |
|----------|----------|
| 순수 값 (`<YOUR_KEY>`) | `cat "$FILE"` |
| 변수 할당 (`KEY=value`) | `source "$FILE"` 후 `$KEY` |

시크릿 파일 생성 시 형식을 문서화하고 일관성 유지가 중요함.
