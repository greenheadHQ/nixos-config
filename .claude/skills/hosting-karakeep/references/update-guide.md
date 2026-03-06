# Karakeep 업데이트 가이드

## 기본 업데이트

- **업데이트**: `sudo karakeep-update --ack-bridge-risk` (수동), `karakeep-version-check` (매일 06:00 자동)
- `--ack-bridge-risk` 없이는 업데이트 스크립트가 중단된다 (브릿지/로그 의존성 인지 강제).

## 로그 모니터 패턴 검증 (필수)

`karakeep-log-monitor` 서비스는 Karakeep 컨테이너의 로그 출력 형식에 의존한다.
**Karakeep 버전 업데이트 후 반드시 아래 패턴이 유효한지 확인해야 한다.**

검증이 누락되면 OOM/크롤 실패 시 Pushover 알림이 발송되지 않아, 크래시 루프를 사용자가 인지하지 못할 수 있다.

**의존 패턴 목록** (현재 기준: `ghcr.io/karakeep-app/karakeep:release`):

| 패턴 | 용도 | 변경 가능성 |
|------|------|-----------|
| `Will crawl "{URL}"` | 크롤 URL 추출 | **높음** -- 로그 모니터가 현재 이 부분만 매칭함 |
| `FATAL ERROR:.*heap out of memory` | V8 OOM 감지 | **낮음** -- Node.js/V8 표준 메시지 |
| `OOM killed (exit code <n>)` | 파서 서브프로세스 OOM 감지 | **중간** -- 로그 모니터가 현재 이 형식을 매칭함 |
| `Crawling job failed:` | 일반 크롤 실패 감지 | **중간** -- Karakeep 자체 메시지 |

**업데이트 후 검증 명령어**:

```bash
# 1. 크롤 URL 패턴 존재 확인
sudo podman logs --tail=200 karakeep 2>&1 | grep -F 'Will crawl "'

# 2. 패턴이 변경되었다면 -> 로그 모니터 스크립트 수정 필요
#    로그 모니터 스크립트 위치: modules/nixos/programs/docker/karakeep-log-monitor/files/log-monitor.sh
#    관련 이슈: #60 (통합 구현 설계 섹션 참조)

# 3. 로그 모니터 서비스 재시작 후 정상 동작 확인
sudo systemctl restart karakeep-log-monitor
journalctl -u karakeep-log-monitor --no-pager -n 20
```

**Breaking change 대응 절차**:

1. 업데이트 후 `sudo podman logs --tail=50 karakeep 2>&1`로 로그 형식 확인
2. `Will crawl` 패턴이 변경되었으면 로그 모니터 스크립트의 regex 수정
3. `karakeep-log-monitor` 서비스 재시작
4. 테스트: 임의 북마크 추가 후 로그 모니터가 URL을 정상 추적하는지 확인

## 환경변수 변경 확인

Karakeep 메이저 업데이트 시 환경변수 이름/기본값이 변경될 수 있다.

```bash
# 현재 설정된 환경변수 확인
sudo podman exec karakeep env | grep -E 'MAX_ASSET|CRAWLER_|NODE_OPTIONS'

# 예상 값:
# MAX_ASSET_SIZE_MB=100
# CRAWLER_NUM_WORKERS=2
# CRAWLER_JOB_TIMEOUT_SEC=180
# NODE_OPTIONS=--max-old-space-size=1536
```

관련 이슈: #60 (대용량 HTML OOM 방지), #59 (알림 미작동)
