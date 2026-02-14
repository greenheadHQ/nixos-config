# immich 설정

MiniPC에서 Podman OCI 컨테이너로 운영되는 immich 사진 관리 서비스 설정입니다.

## 목차

- [개요](#개요)
- [아키텍처](#아키텍처)
- [관련 파일](#관련-파일)
- [컨테이너 구성](#컨테이너-구성)
- [볼륨 매핑](#볼륨-매핑)
- [시크릿 관리](#시크릿-관리)
- [자동 삭제](#자동-삭제)

---

## 개요

immich는 Google Photos 대안으로 사용되는 셀프호스팅 사진/비디오 관리 플랫폼입니다.
MiniPC(greenhead-minipc)에서 NixOS `virtualisation.oci-containers` (Podman 백엔드)로 운영됩니다.

- **런타임**: Podman (`virtualisation.oci-containers.backend = "podman"`)
- **네트워크 접근**: `127.0.0.1:2283` 바인딩 + Caddy HTTPS 리버스 프록시 (`https://immich.greenhead.dev`)
- **활성화**: `homeserver.immich.enable = true;` (mkEnableOption)

## 아키텍처

```
                  Tailscale VPN
                       │
          ┌────────────▼────────────┐
          │   Caddy (HTTPS)         │
          │   immich.greenhead.dev  │
          │   → 127.0.0.1:2283     │
          └────────────┬────────────┘
                       │
     ┌─────────────────▼─────────────────┐
     │         immich-network (Podman)    │
     │                                    │
     │  ┌──────────┐  ┌──────────────┐   │
     │  │ immich-  │  │ immich-ml    │   │
     │  │ server   │  │ (CPU 버전)    │   │
     │  │ :2283    │  │              │   │
     │  └────┬─────┘  └──────────────┘   │
     │       │                            │
     │  ┌────▼─────┐  ┌──────────────┐   │
     │  │ immich-  │  │ immich-redis │   │
     │  │ postgres │  │ (캐시/큐)     │   │
     │  └──────────┘  └──────────────┘   │
     └───────────────────────────────────┘
```

## 관련 파일

| 파일 | 설명 |
|------|------|
| `modules/nixos/programs/docker/immich.nix` | Immich 4개 컨테이너 + 네트워크 정의 |
| `modules/nixos/programs/docker/runtime.nix` | Podman 런타임 공통 설정 (backend, autoPrune) |
| `modules/nixos/programs/docker/immich-backup.nix` | PostgreSQL 매일 백업 (pg_dump -Fc) |
| `modules/nixos/options/homeserver.nix` | mkOption 정의 + 모든 서비스 모듈 import |
| `modules/nixos/programs/immich-cleanup/` | Claude Code Temp 앨범 자동 삭제 |
| `modules/nixos/programs/immich-update/` | Immich 버전 체크 + 업데이트 |
| `modules/nixos/programs/caddy.nix` | Caddy HTTPS 리버스 프록시 |
| `libraries/constants.nix` | IP, 경로, 리소스 제한, UID 상수 |

## 컨테이너 구성

4개 컨테이너가 `immich-network` Podman 네트워크에서 통신:

| 컨테이너 | 이미지 | 역할 | 리소스 제한 |
|----------|--------|------|------------|
| `immich-server` | `ghcr.io/immich-app/immich-server:release` | 웹 서버 + API | `constants.containers.immich.server` |
| `immich-postgres` | `tensorchord/pgvecto-rs:pg16-v0.2.0` | DB (pgvecto-rs) | `constants.containers.immich.postgres` |
| `immich-redis` | `redis:7-alpine` | Job Queue / 캐싱 | `constants.containers.immich.redis` |
| `immich-ml` | `ghcr.io/immich-app/immich-machine-learning:release` | ML (CPU 버전) | `constants.containers.immich.ml` |

### 주요 설정 항목

| 항목 | 설명 |
|------|------|
| ML 컨테이너 | CPU 버전 사용 (OpenVINO OOM 방지) |
| 포트 바인딩 | `127.0.0.1:${cfg.port}:2283` (Caddy가 프록시) |
| 스토리지 | HDD 마운트 경로 (`constants.paths.mediaData`) 사용 |
| 하드웨어 가속 | `--device=/dev/dri` (비디오 트랜스코딩) |
| DB 비밀번호 | agenix 볼륨 마운트 (`POSTGRES_PASSWORD_FILE` / `DB_PASSWORD_FILE`) |
| Redis | 볼륨 없음 (캐싱 전용, 영속성 불필요) |

### 네트워크 생성

`create-immich-network` oneshot 서비스가 부팅 시 Podman 네트워크를 생성하고,
4개 컨테이너 서비스가 이 서비스 이후에 시작되도록 `before` 의존성 설정:

```nix
systemd.services.create-immich-network = {
  after = [ "podman.socket" "network-online.target" ];
  before = [
    "podman-immich-postgres.service"
    "podman-immich-redis.service"
    "podman-immich-ml.service"
    "podman-immich-server.service"
  ];
  serviceConfig.ExecStart = "${pkgs.podman}/bin/podman network create immich-network --ignore";
};
```

## 볼륨 매핑

```nix
# modules/nixos/programs/docker/immich.nix
# immich-server 볼륨
volumes = [
  "${mediaData}/immich/photos:/usr/src/app/upload"
  "${dockerData}/immich/upload-cache:/usr/src/app/upload/upload"
  "/etc/localtime:/etc/localtime:ro"
  "${dbPasswordPath}:/run/secrets/db-password:ro"
];
```

### 경로 변환

| 컨테이너 경로 | 호스트 경로 |
|--------------|------------|
| `/usr/src/app/upload/upload/...` | `${dockerData}/immich/upload-cache/...` |
| `/usr/src/app/upload/library/...` | `${mediaData}/immich/photos/library/...` |

(`dockerData` = `constants.paths.dockerData`, `mediaData` = `constants.paths.mediaData`)

### 디렉토리 권한 (tmpfiles.rules)

```nix
systemd.tmpfiles.rules = [
  "d ${dockerData}/immich/postgres 0755 ${toString postgres} ${toString postgres} -"
  "d ${dockerData}/immich/ml-cache 0755 root root -"
  "d ${dockerData}/immich/upload-cache 0755 ${toString user} ${toString user} -"
  "d ${mediaData}/immich/photos 0755 ${toString user} ${toString user} -"
];
```

UID는 `constants.ids`에서 참조 (postgres=999, user=1000).

## 시크릿 관리

agenix로 3개 시크릿 관리:

| 시크릿 | 용도 |
|--------|------|
| `secrets/immich-db-password.age` | PostgreSQL 비밀번호 (볼륨 마운트 방식) |
| `secrets/immich-api-key.age` | Immich API 키 (cleanup/update에서 사용) |
| `secrets/pushover-immich.age` | Pushover 알림 토큰 |

DB 비밀번호는 `POSTGRES_PASSWORD_FILE` / `DB_PASSWORD_FILE` 환경변수로 컨테이너에 전달됩니다.
`ConditionPathExists`로 시크릿 파일 존재를 확인한 후 서비스가 시작됩니다.

## 자동 삭제

```nix
homeserver.immichCleanup.enable = true;
```

- "Claude Code Temp" 앨범의 모든 이미지를 매일 삭제
- systemd timer로 매일 07:00 KST 실행
- Pushover 알림 전송

상세 설정: [scriptable-immich-upload.md](scriptable-immich-upload.md)

## Claude Code 통합

모바일 SSH 환경에서 Claude Code에 이미지를 전달하기 위해 Immich를 활용합니다.
상세: [mobile-ssh-image.md](mobile-ssh-image.md)
