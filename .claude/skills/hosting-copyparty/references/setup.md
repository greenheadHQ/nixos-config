# Copyparty 설치 및 설정

## 초기 설치 과정

### 1. 상수 추가 (`libraries/constants.nix`)

```nix
network.ports.copyparty = 3923;
containers.copyparty = {
  memory = "1g";
  memorySwap = "1g";
  cpus = "1";
};
```

### 2. 시크릿 생성

```bash
# secrets/secrets.nix에 선언 추가
"copyparty-password.age".publicKeys = allKeys;

# 비밀번호 암호화
agenix -e secrets/copyparty-password.age
# 또는 직접 age 명령어로 암호화
printf '%s\n' "PASSWORD" | age -r "ssh-ed25519 ..." -o secrets/copyparty-password.age
```

### 3. 옵션 정의 (`modules/nixos/options/homeserver.nix`)

```nix
copyparty = {
  enable = lib.mkEnableOption "Copyparty file server (Google Drive alternative)";
  port = lib.mkOption {
    type = lib.types.port;
    default = constants.network.ports.copyparty;
    description = "Port for Copyparty web interface";
  };
};
```

### 4. 서비스 모듈 (`modules/nixos/programs/docker/copyparty.nix`)

핵심 구성요소:
- **copyparty-config** oneshot 서비스: agenix 시크릿에서 비밀번호 추출 → INI 설정 파일 생성
- **copyparty** Podman 컨테이너: `copyparty/ac:latest` 이미지
- **`--entrypoint=python3`**: 이미지 기본 ENTRYPOINT 오버라이드 (initcfg 볼륨 충돌 방지)
- **cmd**: `["-m" "copyparty" "-c" "/cfg/config.conf"]`
- **ConditionPathExists**: 설정 파일 없으면 시작 방지
- **127.0.0.1 바인딩**: Caddy 리버스 프록시가 유일한 외부 진입점

### 5. 활성화

```nix
# modules/nixos/configuration.nix
homeserver.copyparty.enable = true;
```

## Copyparty 설정 파일 형식

INI 스타일, 섹션별 구성:

```ini
[global]
  hist: /cfg/hists        # 히스토리/DB/썸네일 경로 (컨테이너 내부)
  th-maxage: 7776000      # 썸네일 캐시 90일 (초 단위)
  no-crt                  # 자체 TLS 비활성 (Caddy가 HTTPS 처리)
  rproxy: 1               # 리버스 프록시 뒤에서 실행 (X-Forwarded 헤더 신뢰)
  xff-src: 10.88.0.0/16   # Podman 브릿지 네트워크를 프록시 소스로 신뢰

[accounts]
  greenhead: PASSWORD     # 계정: 비밀번호

[/]                       # 가상 경로 (루트)
  /data                   # 컨테이너 내 실제 파일시스템 경로
  accs:
    rwda: greenhead       # 읽기/쓰기/삭제/관리
```

**주의사항**:
- 루트 `[/]` -> `/data` 볼륨 하나만 사용 (하위 경로 별도 마운트 시 충돌)
- `r:` = 읽기 전용, `rwda:` = 전체 권한
- 들여쓰기는 2칸 스페이스 (탭 불가)

## Docker 이미지 정보

- **이미지**: `copyparty/ac:latest` (thumbnailer for audio/video/images + transcoding)
- **기본 포트**: 3923
- **기본 ENTRYPOINT**: `python3 -m copyparty -c /z/initcfg` ← **오버라이드 필수**
- **우리 설정**: `--entrypoint=python3`, cmd: `-m copyparty -c /cfg/config.conf`

### initcfg 내용 (참고용 - 우리는 사용하지 않음)
```ini
[global]
  chdir: /w
  no-crt
% /cfg
```
- `% /cfg`: `/cfg` 디렉토리를 루트 `/`에 볼륨 마운트 (우리 `[/]`와 충돌)
- `no-crt`: HTTPS 비활성 → 우리 config에 직접 포함
- `chdir: /w`: 작업 디렉토리 변경 → 불필요

### 왜 ENTRYPOINT를 오버라이드하는가?
Copyparty의 `-c` 플래그는 설정값(global, accounts)은 오버라이드하지만,
볼륨 매핑(`%`, `[/path]`)은 병합(누적)된다. initcfg의 `% /cfg`가
루트에 볼륨을 생성하므로, 우리 `[/]` -> `/data` 매핑과 충돌한다.
initcfg를 완전히 건너뛰는 것이 유일한 해결책.

## 리소스 설정 근거

- **메모리 1GB + swap 1GB**: FFmpeg 썸네일 생성 시 300-500MB 스파이크 대비
- **CPU 1코어**: 단일 사용자, 다른 서비스 영향 최소화
- **썸네일 캐시 90일**: 적절한 캐시 재활용과 디스크 사용 균형

## WebDAV 연결 (Mac Finder)

1. Finder > 이동 > 서버에 연결 (Cmd+K)
2. `https://copyparty.greenhead.dev` 입력
3. `greenhead` / 비밀번호로 인증
4. Finder에서 직접 파일 탐색/복사/이동 가능

Tailscale VPN 연결 필수 (Caddy가 Tailscale IP에만 바인딩).
