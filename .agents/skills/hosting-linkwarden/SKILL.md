---
name: hosting-linkwarden
description: |
  Linkwarden: bookmark manager, web archiver, Meilisearch, backup.
  Triggers: "linkwarden", "북마크", "bookmark", "웹 아카이브", "web archive",
  "linkwarden 설정", "linkwarden 백업", "archive.greenhead.dev",
  "meilisearch", "검색 엔진", "linkwarden 업데이트", "linkwarden 복원",
  "브라우저 확장", "browser extension", "linkwarden 버전".
---

# Linkwarden 북마크 매니저 + 웹 아카이버 관리

NixOS 네이티브 서비스로 실행되는 셀프호스팅 북마크 매니저 + 웹 아카이버입니다.
Caddy HTTPS 리버스 프록시(`https://archive.greenhead.dev`)를 통해 Tailscale VPN 내에서 접근합니다.
Meilisearch로 풀텍스트 검색을 지원하며, PostgreSQL DB는 NixOS가 자동 관리합니다.

**중요**: Linkwarden은 Podman 컨테이너가 아닌 NixOS 네이티브 서비스입니다.

## 모듈 구조

| 파일 | 역할 |
|------|------|
| `modules/nixos/options/homeserver.nix` | `linkwarden`, `meilisearch`, `linkwardenBackup`, `linkwardenUpdate` mkOption 정의 |
| `modules/nixos/programs/linkwarden/default.nix` | 서비스 설정 (NixOS 네이티브 모듈 래핑) |
| `modules/nixos/programs/linkwarden-backup/default.nix` | 매일 PostgreSQL 백업 (pg_dump → HDD) |
| `modules/nixos/programs/linkwarden-update/default.nix` | 버전 체크 + Pushover 알림 |
| `modules/nixos/programs/caddy.nix` | Caddy HTTPS 리버스 프록시 (archive.greenhead.dev) |
| `secrets/linkwarden-nextauth-secret.age` | NEXTAUTH_SECRET |
| `secrets/meilisearch-master-key.age` | Meilisearch 인증 키 |
| `secrets/pushover-linkwarden.age` | Pushover 알림 크리덴셜 |
| `libraries/constants.nix` | 포트 (`linkwarden = 3000`, `meilisearch = 7700`), 서브도메인 (`archive`) |

## 빠른 참조

### 접근 방법

| 방식 | URL |
|------|-----|
| 웹 UI | `https://archive.greenhead.dev` |
| 내부 (localhost) | `http://127.0.0.1:3000` |
| Meilisearch | `http://127.0.0.1:7700` |

### 서비스 관리

```bash
systemctl status linkwarden                    # 서비스 상태
systemctl status meilisearch                   # Meilisearch 상태
systemctl status postgresql                    # PostgreSQL 상태
journalctl -u linkwarden -f                    # 로그 실시간
ss -tlnp | grep -E '3000|7700'                 # 포트 리스닝 확인
curl -sf http://localhost:3000/                # Linkwarden 헬스체크
curl -sf http://localhost:7700/health          # Meilisearch 헬스체크
```

### 백업

```bash
sudo systemctl start linkwarden-db-backup.service  # 수동 백업
systemctl list-timers | grep linkwarden              # 타이머 확인
ls -la /mnt/data/backups/linkwarden/                 # 백업 파일 확인
journalctl -u linkwarden-db-backup.service           # 백업 로그
```

백업 구조:
- **PostgreSQL**: `pg_dump -Fc` → `pg_restore --list` 무결성 검증
- **보존**: 30일
- **스케줄**: 매일 05:00 KST
- **위치**: `/mnt/data/backups/linkwarden/`

### 버전 체크

```bash
sudo systemctl start linkwarden-version-check.service  # 수동 체크
journalctl -u linkwarden-version-check.service         # 체크 로그
```

- **스케줄**: 매일 06:00 KST
- **비교**: `pkgs.linkwarden.version` (빌드 시 고정) vs GitHub latest release
- **업데이트**: `nix flake update` + `nrs` (수동, 컨테이너와 다름)

### 클라이언트 설정

**Chrome 확장 프로그램**:
1. Chrome Web Store에서 Linkwarden 확장 설치
2. Settings > Instance URL: `https://archive.greenhead.dev`
3. API Key 또는 이메일/비밀번호로 로그인

**iOS 앱**:
1. App Store에서 Linkwarden 설치
2. Server URL: `https://archive.greenhead.dev`
3. 로그인 후 공유 시트에서 바로 아카이빙 가능

### 서비스 활성화/비활성화

```nix
# modules/nixos/configuration.nix
homeserver.linkwarden.enable = true;
homeserver.meilisearch.enable = true;
homeserver.linkwardenBackup.enable = true;
homeserver.linkwardenUpdate.enable = true;
```

## 스토리지 구조

| 경로 | 디스크 | 용도 |
|------|--------|------|
| `/mnt/data/linkwarden/archives` | HDD | 아카이브 파일 (스크린샷, PDF, HTML) |
| `/var/lib/postgresql` | SSD | PostgreSQL DB (NixOS 자동 관리) |
| `/var/lib/meilisearch` | SSD | Meilisearch 인덱스 |
| `/var/cache/linkwarden` | SSD | 애플리케이션 캐시 |
| `/mnt/data/backups/linkwarden` | HDD | 일일 백업 (30일 보존) |
| `/var/lib/linkwarden-update` | SSD | 버전 체크 상태 |

## Known Issues

**JS 렌더링 페이지 아카이빙 실패**
- SPA(React, Vue 등) 페이지는 아카이빙이 실패할 수 있음
- 스크린샷은 항상 캡처됨 (HTML/PDF 실패 시 대안)

**인증 필요 페이지 아카이빙 불가**
- 로그인이 필요한 페이지는 아카이빙 불가 (알려진 제한)
- 워크아라운드 없음

**NixOS 네이티브 서비스 업데이트 방식**
- 컨테이너 서비스와 달리 `sudo linkwarden-update` 명령 없음
- 업데이트: `nix flake update` → `nrs` (nixpkgs 채널을 통해 업데이트)
- 버전 체크만 자동, 실제 업데이트는 수동

**첫 사용자 등록**
- `enableRegistration = false`여도 첫 번째 사용자는 등록 가능
- 첫 사용자 등록 후 추가 등록 차단됨

**PostgreSQL 공존**
- `database.createLocally = true`는 NixOS `services.postgresql` 사용
- Immich의 컨테이너 내 PostgreSQL과는 별도 (충돌 없음)

## 자주 발생하는 문제

1. **서비스 시작 실패**: `journalctl -u linkwarden`에서 원인 확인. NEXTAUTH_SECRET 누락 가능
2. **Meilisearch 연결 실패**: `curl http://localhost:7700/health`로 상태 확인
3. **아카이브 파일 저장 실패**: HDD 마운트 확인 (`mount | grep /mnt/data`)
4. **HTTPS 접근 불가**: Caddy 상태 확인 (`systemctl status caddy`), Tailscale 연결 확인
5. **검색 안 됨**: Meilisearch 인덱스 확인 (`curl http://localhost:7700/indexes`)
6. **백업 실패**: PostgreSQL 실행 확인 (`systemctl status postgresql`)

## 레퍼런스

- 설정/운영 상세: [references/setup.md](references/setup.md)
- 트러블슈팅: [references/troubleshooting.md](references/troubleshooting.md)
