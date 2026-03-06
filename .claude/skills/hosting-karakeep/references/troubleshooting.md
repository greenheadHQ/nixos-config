# Karakeep 트러블슈팅

## 1. CSS 렌더링 깨짐 (아카이브 인라인 뷰)

Karakeep의 CSP 헤더가 iframe 내 CSS를 차단하는 알려진 버그.
임시 우회책으로 Caddy에서 CSP 제거 가능 (`caddy.nix` -- `header -Content-Security-Policy`).
다만 이는 인라인 아카이브 뷰의 XSS 방어를 약화시키므로, Tailscale 내부 전용 환경에서만 제한적으로 적용하고
업스트림 수정이 가능해지면 원복하는 편이 안전하다.
ref: https://github.com/karakeep-app/karakeep/issues/1977

## 2. 웹훅 전달 실패

v0.30.0+에서 내부 IP 웹훅 기본 차단.
`CRAWLER_ALLOWED_INTERNAL_HOSTNAMES=host.containers.internal` 확인.
```bash
journalctl -u karakeep-webhook-bridge -f
```

## 3. SingleFile ZodError (field name 누락)

SingleFile 확장에서 push 시 아래 에러 발생:
```json
{"success":false,"error":{"issues":[{"code":"invalid_type","expected":"string","received":"undefined","path":["url"],"message":"Required"},{"code":"custom","message":"Input not instance of File","fatal":true,"path":["file"]}],"name":"ZodError"}}
```
**원인**: SingleFile 확장 설정에서 `archive data field name`, `archive URL field name` 필드가 비어있음.
**해결**: 각각 `file`, `url`을 입력. 이 필드들은 SingleFile 확장이 기본값을 제공하지 않으므로 반드시 수동 입력 필요.

## 4. 컨테이너 OOM

리소스 제한: `libraries/constants.nix` -> `constants.containers.karakeep`
```bash
podman stats --no-stream karakeep karakeep-chrome karakeep-meilisearch
```

**Meilisearch 메모리 기준**: 안정 시 ~365MB 사용.
512MB 제한에서 OOM 크래시 루프 발생 (98% 점유로 반복 kill).
**최소 1GB 확보 필요** -- Meilisearch가 죽으면 Karakeep 앱도 의존성 실패로 502 발생.

## 5. AI 태깅/요약 미동작

점검 순서:

1. `karakeep-openai-key.age`가 실제 키로 갱신되었는지 확인 (placeholder 금지)
2. `karakeep-env.service`, `karakeep-openai-env.service` 실행 성공 여부 확인
3. Karakeep 컨테이너 로그에서 OpenAI 요청 오류(401/429/timeout) 확인

```bash
sudo systemctl status karakeep-env.service karakeep-openai-env.service --no-pager
sudo podman logs --tail=200 karakeep
journalctl -u podman-karakeep.service -n 200 --no-pager
```

## 6. 모바일 앱 (iOS/Android)

- App Store: "Karakeep" 검색
- 서버 URL: `https://archive.greenhead.dev`
- 인라인 아카이브 뷰에서 CSS 깨짐은 웹과 동일 (CSP 제거로 해결)

## 7. Restore (백업 복원)

```bash
# 1. 서비스 중지
sudo systemctl stop podman-karakeep.service

# 2. 백업에서 DB 복원
sudo gunzip -k /mnt/data/backups/karakeep/YYYY-MM-DD/db.db.gz
sudo cp /mnt/data/backups/karakeep/YYYY-MM-DD/db.db /mnt/data/karakeep/db.db
sudo gunzip -k /mnt/data/backups/karakeep/YYYY-MM-DD/queue.db.gz
sudo cp /mnt/data/backups/karakeep/YYYY-MM-DD/queue.db /mnt/data/karakeep/queue.db

# 3. 서비스 재시작
sudo systemctl start podman-karakeep.service
```
