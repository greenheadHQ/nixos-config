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
- **copyparty** Podman 컨테이너: `copyparty/ac:latest` 이미지, `-c /cfg/config.conf` 인자
- **ConditionPathExists**: 설정 파일 없으면 시작 방지
- **tailscale-wait.nix**: Tailscale IP 준비 대기

### 5. 활성화

```nix
# modules/nixos/configuration.nix
homeserver.copyparty.enable = true;
```

## Copyparty 설정 파일 형식

INI 스타일, 섹션별 구성:

```ini
[global]
  hist: /cfg/hists        # 히스토리/DB/썸네일 경로
  th-maxage: 7776000      # 썸네일 캐시 90일 (초 단위)

[accounts]
  greenhead: PASSWORD     # 계정: 비밀번호

[/path]                   # 볼륨 매핑 경로
  /container/path         # 컨테이너 내 실제 경로
  accs:
    r: greenhead          # 읽기 전용
    rwda: greenhead       # 읽기/쓰기/삭제/관리
```

## Docker 이미지 정보

- **이미지**: `copyparty/ac:latest` (thumbnailer for audio/video/images + transcoding)
- **기본 포트**: 3923
- **ENTRYPOINT**: `python3 -m copyparty -c /z/initcfg`
- **`-c` 플래그**: 반복 가능, 나중 설정이 이전을 오버라이드

## 리소스 설정 근거

- **메모리 1GB + swap 1GB**: FFmpeg 썸네일 생성 시 300-500MB 스파이크 대비
- **CPU 1코어**: 단일 사용자, 다른 서비스 영향 최소화
- **썸네일 캐시 90일**: 적절한 캐시 재활용과 디스크 사용 균형

## WebDAV 연결 (Mac Finder)

1. Finder > 이동 > 서버에 연결 (Cmd+K)
2. `http://100.79.80.95:3923` 입력
3. `greenhead` / 비밀번호로 인증
4. Finder에서 직접 파일 탐색/복사/이동 가능

Tailscale VPN 연결 필수.
