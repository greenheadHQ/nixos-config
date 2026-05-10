# 학습 세션 — 2026-05-10

## 메타데이터

| 항목 | 값 |
|------|-----|
| 일시 | 2026-05-10 |
| 학습 시간 | 약 70분 |
| 카드 수 | 5장 (Anki lapses 상위 카드) |
| 평균 점수 | 63.6 / 100 |
| 호스팅 | 임시 — Tailscale `100.79.80.95:8001`, Python http.server (`server.py`, repo 미포함, Future Ideas로 영구화 예정) |
| LLM | Claude Code (Opus 4.7 / 1M context) |
| 관련 이슈 | [#711](https://github.com/greenheadHQ/nixos-config/issues/711) |

## 카드별 결과

| # | 카드 | 점수 | 자기평가 | lapses 변화 (예측) | 답안 JSON | HTML |
|---|------|------|----------|---------------------|-----------|------|
| 1 | 교착 4조건 | 93 | Good | 7 → 감소 예상 | `answers/01_deadlock_4conditions.json` | `index.html` |
| 2 | 시스템 콜과 이중 모드 | 84 | Hard | 6 → 감소 | `answers/02_syscall_dual_mode.json` | `syscall.html` |
| 3 | TLB / 페이지 테이블 | 26 | Again | 6 → 유지 (정보량 과다) | `answers/03_tlb_page_table.json` | `tlb.html` |
| 4 | 네트워크 인터페이스/NIC | 51 | Again | 5 → 감소 (매핑 보강 필요) | `answers/04_nic.json` | `nic.html` |
| 5 | TCP/IP ↔ OSI | 64 | Hard | 5 → 감소 (이름 회상 약함) | `answers/05_tcpip_osi.json` | `tcpip.html` |

## 사용자 명시 — 좋았던 점

- 실제로 코드를 작성할 수 있는 문제가 있었음
- LLM이 YAGNI한 부분을 알아서 필터링해줌 (특히 TCP/IP 카드)

## 사용자 명시 — 안 좋았던 점

- LLM이 노트 내용만 그대로 믿고 팩트 체크 안 함 (일부 카드)
- 모든 문제가 단순 선택 문제 — 단조로움
- 시각 자료 부족 — 이해 어려움

## AI 자기 평가 — 일관성 결함

- 5개 중 팩트체크/YAGNI 보강을 일관되게 적용한 건 시스템콜·TLB·TCP/IP 뿐
- 교착·NIC는 책 내용 거의 그대로 (사용자 명시 요구 전이라 약함)
- 이 결함은 다음 세션 GUIDE.md "팩트체크 의무" 항목으로 박제

## 이미지 자산 매핑

| 카드 | 사용 이미지 | 미사용 (보존만) |
|------|------------|-----------------|
| 교착 (index.html) | `img1.png`, `img2.png` | — |
| 시스템 콜 (syscall.html) | `sc_flow.png`, `sc_modes.png` | `sc_hello.png`, `sc_kernel_area.png`, `sc_sync.png` |
| TLB (tlb.html) | `tlb_flow.png`, `tlb_ptbr.png` | — |
| NIC (nic.html) | (페이지에서 미참조) | `nic_card.png`, `nic_external.png` |
| TCP/IP (tcpip.html) | (페이지에서 미참조) | `tcpip_5layer.png`, `tcpip_compare.png` |

미사용 이미지도 함께 보존한다 — 학습 컨텍스트의 일부로서, 다음 세션 LLM이 어떤 이미지를 추출했는지 기록 (issue #711 D-2 결정).

## 영감 / 시도 배경

- 영감 아티클: <https://x.com/trq212/article/2052809885763747935> · <https://thariqs.github.io/html-effectiveness/>
- 핵심 가치 발견: **"준비 부담 0 = LLM에게 부탁만 하면 됨"**
- 시도: lapses 상위 5개 카드를 LLM이 인터랙티브 HTML로 변환 → minipc 호스팅 → Tailscale 내부 학습 + AI 채점

## 다음 세션 트리거

세션 시작 전 [`../../GUIDE.md`](../../GUIDE.md) 를 LLM에게 입력으로 제공.
세션 종료 후 새 `sessions/<date>/` 디렉토리 + 본 형식의 SESSION.md 추가.
