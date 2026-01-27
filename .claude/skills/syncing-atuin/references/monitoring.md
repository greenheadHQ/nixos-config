# Atuin 모니터링 시스템

Atuin 동기화 상태를 모니터링하고, 동기화 지연 시 알림을 전송합니다.

## 목차

- [아키텍처](#아키텍처)
- [기능](#기능)
- [메뉴바](#메뉴바)
- [상태 판단 기준](#상태-판단-기준)
- [알림](#알림)
- [설정값](#설정값)
- [Alias](#alias)
- [알려진 문제](#알려진-문제)

---

> **테스트 버전**: atuin 18.10.0

`modules/darwin/programs/atuin/`에서 관리됩니다.

## 아키텍처

```
auto_sync (atuin 내장)
    │
    └──▶ 터미널 명령 실행 시 sync_frequency (1분) 간격으로 자동 sync

Hammerspoon 메뉴바 (1분마다)
    │
    └──▶ 🐢 아이콘 상태 업데이트

com.green.atuin-watchdog (launchd, 10분마다)
    │
    ├──▶ 동기화 상태 점검
    └──▶ 지연 시 알림 전송
```

> **참고**: 동기화는 atuin 내장 `auto_sync`가 담당합니다. watchdog은 모니터링 + 알림만 수행합니다.

## 기능

| 컴포넌트 | 역할 |
| ---- | ---- |
| auto_sync (atuin 내장) | 터미널 명령 실행 시 sync_frequency (1분) 간격으로 자동 sync |
| com.green.atuin-watchdog | 10분마다 상태 체크 + 알림 |
| Hammerspoon 메뉴바 | 🐢 아이콘으로 상태 표시, 1분마다 갱신 |

## 메뉴바

| 항목 | 설명 |
| ---- | ---- |
| 아이콘 | 🐢 (항상 고정) |
| 상태 문장 | O 정상 / 경고 / X 에러 |
| 정보 표시 | 마지막 동기화, 히스토리 개수, 설정값 |

클릭 시 메뉴 예시:
```
🐢
├─ O 정상 (마지막 동기화: 1분 전)
├─ ─────────────
├─ 마지막 동기화: 2026-01-13 17:42:42 (1분 전)
├─ 히스토리: 63개
├─ ─────────────
├─ 상태 체크 주기: 10분마다
└─ 동기화 경고 임계값: 5분
```

## 상태 판단 기준

| 상태 | 조건 | 표시 |
| ---- | ---- | ---- |
| 정상 | 5분 이내 동기화됨 | O 정상 (마지막 동기화: N분 전) |
| 경고 | 5분 초과 | 경고: 동기화 지연 (N분 초과) |
| 에러 | 파일 없음/파싱 실패 | X 오류 발생 |

## 알림

| 상황 | 알림 |
| ---- | ---- |
| 5분~30분 지연 | macOS 알림 + Hammerspoon |
| 30분 초과 | macOS 알림 + Hammerspoon + Pushover |

## 설정값

`modules/shared/programs/shell/default.nix`에서 중앙 관리:

```nix
programs.atuin.settings = {
  auto_sync = true;
  sync_frequency = "1m";
  sync.records = true;         # v2 API 사용
  search_mode = "fulltext";    # 정확한 검색 (fuzzy 대신)
  # ...
};
```

watchdog 설정 (`modules/darwin/programs/atuin/default.nix`):

```nix
syncCheckInterval = 600;        # 10분 (초) - watchdog 실행 주기
syncThresholdMinutes = 5;       # 5분 - 경고 임계값
```

## Alias

| Alias | 명령어 | 설명 |
| ----- | ------ | ---- |
| `awd` | `~/.local/bin/atuin-watchdog.sh` | 수동 실행 |

```bash
# launchd 상태 확인
launchctl list | grep atuin

# 로그 확인
tail -f ~/.local/share/atuin/watchdog.log
```

## 알려진 문제

| 문제 | 설명 | 상태 |
| ---- | ---- | ---- |
| `atuin status` 404 | Atuin 서버가 Sync v1 API 비활성화 | 무시해도 됨 |
| fuzzy search 오매칭 | 기본 fuzzy 모드는 의도치 않은 결과 포함 | `search_mode = "fulltext"`로 해결 |
| `atuin history delete` 미존재 | v18.11.0에 해당 서브커맨드 없음, SQLite 직접 수정 필요 | 우회 적용 |
| 한글 히스토리 TUI 깨짐 | zsh-autosuggestions 0.7.1이 한글 너비 계산 오류 | 히스토리 삭제로 완화 |

> **참고**: 자세한 트러블슈팅은 TROUBLESHOOTING.md의 Atuin 관련 섹션을 참고하세요.
