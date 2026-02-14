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

### Tailscale IP 바인딩 부팅 순서 이슈 (히스토리)

**날짜**: 2026-01-21

**과거 증상**: 컨테이너가 Tailscale IP(`100.x.x.x`)에 직접 바인딩되던 시점에, 부팅 직후 IP 할당 타이밍 문제로 서비스가 실패:

```
bind: cannot assign requested address
```

**원인**:

`tailscaled.service`가 started 상태여도 Tailscale IP가 실제 인터페이스에 준비되기 전일 수 있습니다.
그래서 단순 `after = [ "tailscaled.service" ]`만으로는 충분하지 않았습니다.

**현재 상태 (2026-02 기준)**:

- Immich/Uptime Kuma/Copyparty/Vaultwarden은 `127.0.0.1` 바인딩으로 전환됨
- 외부 접근은 Caddy가 Tailscale IP(`443`)에서 reverse proxy
- 따라서 위 컨테이너들은 더 이상 Tailscale IP 직접 바인딩 실패를 겪지 않음

**여전히 Tailscale 대기가 필요한 곳**:

| 서비스 | 이유 |
|------|------|
| `caddy.service` | Tailscale IP에 직접 bind |
| `anki-sync-server.service` | Tailscale IP에 직접 bind |
| `immich-cleanup`/`immich-version-check` 등 | 외부 네트워크 의존 작업 전 준비 대기 |

공통 대기 로직은 `modules/nixos/lib/tailscale-wait.nix`를 사용합니다.

**검증**:

```bash
# 컨테이너는 localhost 포트에 열려 있어야 함
curl -I http://127.0.0.1:2283  # immich
curl -I http://127.0.0.1:3002  # uptime-kuma

# Tailscale IP bind 서비스 상태
systemctl status caddy
systemctl status anki-sync-server
```

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
