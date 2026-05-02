# Review Intensity 판단 규칙

Review Intensity 판단 알고리즘 규칙의 단일 소스. SKILL.md와 독립 에이전트 프롬프트 모두 이 파일을 참조한다.
SKIP/LITE/FULL 절차(실행 방법)는 [`intensity-procedure.md`](intensity-procedure.md)에 정의되어 있다.

해석 규칙:
- 여기서 **FULL**은 4 reviewer bundle 기본 리뷰를 뜻하며, 기본 fan-out은 4 reviewer bundle이다.
- 명시적 `full` modifier는 Review Intensity를 건너뛰고 exhaustive override(8개 세부 도메인)로 진입한다.
- policy-file 변경을 더 공격적으로 downscale하는 실험은 P1 범위다. 이번 P0에서는 현재 FULL safety rule을 유지한다.

## 판단 알고리즘

다음 순서로 평가한다. **먼저 매치된 조건이 우선**한다:

1. `full` modifier → **FULL**
2. 보안 관련 변경 (인증, 권한, 시크릿, 네트워크 노출, TLS, systemd 보안 옵션 삭제/완화, 파일 권한 mode 변경) → **FULL**
3. 새 모듈/서비스 추가, 서비스 enable 토글(enable=false→true 포함), 아키텍처/인터페이스 변경 → **FULL**
4. 설정/포트/환경변수/의존성/리소스 제한(메모리·CPU·타임아웃)/시스템 파라미터(커널·watchdog·부트) 변경 → **FULL**
5. 단일 함수 소규모 수정, 리팩터링 → **LITE**
6. 순수 문서/주석/오타/whitespace/CHANGELOG → **SKIP** (단, 에이전트 실행 정책 파일 — SKILL.md, hooks/*, settings.json, AGENTS*.md — 은 문서가 아닌 코드 변경으로 취급하여 FULL)
7. 혼합 변경 → 포함된 변경 중 **가장 높은 단계** 적용
8. 불명확 → **FULL**

## 예시

| 변경 유형 | 단계 | 이유 |
|----------|------|------|
| README 오타, 주석 오탈자 | SKIP | 비실행 텍스트 |
| docstring 업데이트 | SKIP | 비실행 텍스트 |
| 기존 함수의 소규모 로직 수정 | LITE | 단일 함수, 구조 변경 없음 |
| flake.lock hash 업데이트 | FULL | 의존성 변경 (규칙 4) |
| 포트 번호 변경 | FULL | 설정/포트 변경 (규칙 4) |
| 새 NixOS 모듈 추가 | FULL | 새 모듈 (규칙 3) |
| secrets.nix 수정 | FULL | 보안 관련 (규칙 2) |
| README 오타 + 포트 변경 혼합 | FULL | 혼합: 가장 높은 FULL 적용 (규칙 7) |
| Nix 옵션값(메모리/타임아웃) 변경 | FULL | 리소스 제한 변경 (규칙 4) |
| systemd NoNewPrivileges 삭제 | FULL | 보안 옵션 완화 (규칙 2) |
| homeserver.X.enable 토글 | FULL | 서비스 enable 토글 (규칙 3) |
| 파일 권한 mode 0400→0644 변경 | FULL | 파일 권한 완화 (규칙 2) |
| download-buffer-size 설정 변경 | FULL | 설정 변경 (규칙 4) |
