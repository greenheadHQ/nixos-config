---
name: show-pains
disable-model-invocation: true
description: |
  Pain point 히스토리를 인터랙티브 HTML 대시보드로 시각화.
  Trigger: '/show-pains', 'pain point 보여줘', 'pain 대시보드', 'pain 히스토리'.
---

# Pain Point 대시보드

`~/.claude/pain-points.jsonl` + `~/.claude/pain-points.archive.jsonl`을 합쳐
인터랙티브 HTML 대시보드로 시각화한다. 최근 30일 롤링 뷰.

## 사용법

Bash tool로 스크립트를 실행한다:

```bash
~/.claude/scripts/show-pain-points.sh
```

스크립트가 HTML 파일을 생성하고 브라우저를 자동으로 연다.

## 데이터 소스

| 파일 | 보존 기간 | 설명 |
|------|----------|------|
| `${PAIN_POINTS_FILE:-~/.claude/pain-points.jsonl}` | 최근 7일 | active pain points |
| `${PAIN_ARCHIVE_FILE:-~/.claude/pain-points.archive.jsonl}` | 최근 30일 | 정제 후 archive |

데이터가 없으면 안내 메시지를 출력하고 종료한다.

## 대시보드 기능

- **요약 카드**: 총 수, HIGH/MEDIUM/MANUAL 각 수
- **일별 트렌드 차트**: bucket별 색상 라인 (Chart.js)
- **필터**: Bucket, Source, Repo
- **테이블**: 시간 역순, bucket 뱃지, description, reason, repo/branch
- **반복 패턴**: 동일 repeat key (keyword > user_note > description fallback) 3회+ 반복 하이라이트
