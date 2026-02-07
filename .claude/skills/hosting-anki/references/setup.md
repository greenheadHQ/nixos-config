# Anki Sync Server 설치/설정 상세

## NixOS 모듈 옵션

```nix
# modules/nixos/options/homeserver.nix
ankiSync = {
  enable = lib.mkEnableOption "Anki self-hosted sync server";
  port = lib.mkOption {
    type = lib.types.port;
    default = constants.network.ports.ankiSync;  # 27701
    description = "Port for Anki sync server";
  };
};
```

## agenix 시크릿 관리

비밀번호 파일 위치: `secrets/anki-sync-password.age`

```bash
# 비밀번호 생성/변경 (MiniPC에서 실행)
cd ~/IdeaProjects/nixos-config
nix run github:ryantm/agenix -- -e secrets/anki-sync-password.age
# 에디터에서 비밀번호만 입력 (KEY=value 형식 아님, 평문 비밀번호)

# 비밀번호 확인
sudo cat /run/agenix/anki-sync-password
```

NixOS 시스템 레벨 agenix 사용 (`age.secrets.*`). Home Manager 레벨이 아님.

## 클라이언트 URL 형식

- Sync URL: `http://<tailscale-ip>:<port>/`
- 끝에 `/` 슬래시 필수
- Media sync URL: 비워둠 (최신 Anki는 자동으로 같은 URL 사용)
- HTTPS 불필요 (Tailscale이 WireGuard 암호화 제공)

## AnkiWeb에서 마이그레이션

### 순서

1. 모든 기기에서 AnkiWeb에 마지막 동기화
2. macOS Desktop: 커스텀 sync 서버 URL 설정 + Anki 재시작
3. Desktop에서 Sync → **"Upload"** 선택 (로컬 → 서버)
4. `ls -la /var/lib/anki-sync-server/` 에서 사용자 데이터 확인
5. AnkiMobile: 커스텀 sync 서버 URL 설정
6. AnkiMobile에서 Sync → **"Download"** 선택 (서버 → 아이폰)
7. 양쪽 기기에서 카드 수, 덱 목록 일치 확인

### 되돌리기

커스텀 sync 서버 필드를 비우면 AnkiWeb으로 복귀.
AnkiWeb 계정은 백업으로 유지 가능 (동기화만 중단됨).

## backup.colpkg 복원

비상 시 `.colpkg` 파일로 복원:

1. Anki Desktop에서 File > Import
2. `backup.colpkg` 선택
3. Sync → "Upload" 선택

## 백업 구조

- 소스: `/var/lib/anki-sync-server/` (SSD)
- 백업: `/mnt/data/backups/anki/YYYY-MM-DD/` (HDD)
- 보존: 7일
- 스케줄: 매일 04:00 KST

## 검증 기준값

마이그레이션 후 AnkiConnect API(localhost:8765)로 대조:

| 항목 | 기대값 |
|------|--------|
| 총 노트 수 | 811 |
| 총 카드 수 | 980 |
| 총 리뷰 기록 수 | 9,270 |
| 미디어 파일 수 | 1,229 |
| 덱 수 | 15 |
| 태그 수 | 22 |
