"""anki_mcp — headless Anki(MiniPC)용 원격 MCP 서버.

구성 요소 (plan 030 PR 2a):
  config.py      env → Settings (nixos 모듈이 단일 소스에서 주입)
  ankiconnect.py loopback AnkiConnect(HTTP) 클라이언트 — 컬렉션 조회·변경은 전부 이 경로
  helper.py      anki_host_sync 헬퍼 애드온(/status) — 변경 작업 전 busy 확인 (결정 10)
  syncstatus.py  "지금 동기화" — sync 유닛 트리거 + 상태 사본(runId 규칙, 결정 13·15)
  shaping.py     응답 축소(필드 절단·페이지네이션)
  tools.py       MCP 도구 정의(조회 계층 + 변경 계층의 추가·수정·태그, annotations)
  oauth.py       내장 OAuth 2.1 AS provider — 파일 영속(클라이언트·토큰 해시), PKCE·DCR·갱신·철회
  approval.py    승인 화면(tailnet 전용 포트) — 비밀 문구 + 잠금
  server.py      Funnel 앱(/mcp·메타데이터·토큰)과 승인 앱(/authorize·/approve)을 서로 다른 loopback 포트에 띄운다

신뢰 경계: 이 프로세스는 Tailscale Funnel로 인터넷에 노출된다. Anki 데이터는 파일로 만지지 않고
AnkiConnect·헬퍼 HTTP로만 다루며, 별도 시스템 유저(anki-mcp)로 돌아 컬렉션 디렉터리(0700)에 닿지 않는다.
"""

__version__ = "0.1.0"
