# Arbiter 판정 안정성 측정

run-da Arbiter가 동일 finding에 대해 round마다 상반된 verdict를 내는 `criteria drift`(Shankar et al. 2024)를 줄이기 위한 selective consistency 정책과 offline 관찰 지표를 정의한다.

이 문서가 Arbiter 안정성 정책(threshold, trigger 조건, stability_status 의미)의 **단일 진실 원천**이다. 다른 파일은 재서술 대신 여기를 링크한다.

| 문서 | 담당 |
|------|------|
| 이 문서 (`stability-measurement.md`) | 정책 정의 (trigger 조건, threshold, stability_status enum) |
| [`protocol.md`](protocol.md) | 상태 전이 (verdict × stability_status → 메인 에이전트 행동) |
| [`arbiter-scaling.md`](arbiter-scaling.md) | 런타임 실행 계약 (Codex 세션 / codex exec 병렬 실행 방법, 실패 처리) |
| [`arbiter-prompt.md`](arbiter-prompt.md) | VERDICT_JSON 블록 스키마, 5가지 판정 기준, Few-shot |

## v1 정책: vote-shape 기반 selective consistency

v1 실시간 판정은 **vote-shape**(N=3 Arbiter의 verdict 분포)만 사용한다. Fleiss kappa는 v1 실시간 분기에 사용하지 않는다 (offline 관찰 전용, 아래 섹션 참조).

### vote-shape 분류

N=3 독립 Arbiter 판정에서 나올 수 있는 verdict 분포는 세 가지다.

| vote-shape | 의미 | stability_status | 메인 에이전트 행동 |
|-----------|------|------------------|-------------------|
| `3:0` | 3명 모두 같은 verdict | `stable` | majority verdict 자동 adoption (기존 CONFIRMED/NOT_AN/NEEDS_MORE 경로 진입) |
| `2:1` | 다수·소수 분리 | `split` | NEEDS_MORE_INFO로 보고, AskUserQuestion 필수 |
| `1:1:1` | 세 verdict가 모두 다름 | `fragmented` | BLOCKED 상태로 기록, 자동 수정 금지 |

상세한 상태 전이 규칙(BLOCKED 상태 처리, AskUser 미지원 런타임 대응)은 [`protocol.md`](protocol.md) 참조.

### stability_status enum 정의

VERDICT_JSON aggregate 출력의 `stability_status` 필드는 아래 4가지 정책 값 중 하나다.

- `N/A`: first-pass single Arbiter 판정이거나 selective consistency를 실행하지 않은 경우. 기본값.
- `stable`: N=3 재판정 결과가 `3:0` (unanimous).
- `split`: N=3 재판정 결과가 `2:1` (majority + minority).
- `fragmented`: N=3 재판정 결과가 `1:1:1` (no majority).

**Sentinel**: harness가 정책 범위 밖 입력(N≠3)을 받으면 `stability_status="unknown"`으로 표기한다. 이 값은 정책 enum이 아니라 "정책 범위 밖 입력" sentinel이며, caller는 이를 `fragmented`/`partial_failure`와 동일하게 BLOCKED로 처리한다. `fleiss-kappa.py`의 `classify_vote_shape` docstring 참조.

## Selective consistency 트리거 (OR 3조건)

Arbiter first-pass 결과가 아래 **세 조건 중 하나라도 만족**하면 N=3 재판정을 실행한다. 모든 finding에 N=3을 적용하는 것은 비용이 폭증하므로 애매한 finding에만 적용한다 (Jung et al. 2024 "Trust or Escalate").

1. **first-pass 신뢰도 LOW**: Arbiter가 VERDICT_JSON에 `"confidence": "LOW"`를 반환한 경우.
2. **first-pass NEEDS_MORE_INFO**: first-pass verdict가 `NEEDS_MORE_INFO`인 경우.
3. **이전 outer round 반복**: 같은 finding ID가 이전 outer round에서도 동일 파일:줄 또는 계획 항목에 대해 등장한 경우.

각 조건은 독립적이며 OR 관계다. 세 조건 중 하나라도 매치되면 trigger된다. 매치되지 않은 finding은 first-pass 결과를 그대로 사용한다 (N=1, stability_status=`N/A`).

### 트리거되지 않는 경우

- first-pass 신뢰도 HIGH/MEDIUM + CONFIRMED_ISSUE/NOT_AN_ISSUE → selective consistency 생략, stability_status=`N/A`.
- 비용 이유로 LITE 모드에서는 trigger 조건 (1)만 활성화 (논란이 큰 LOW-confidence만 재판정).

## Offline 관측 (Fleiss kappa)

v1에서 Fleiss kappa는 **실시간 threshold 분기에 사용하지 않는다**. 배포 후 Arbiter 안정성을 장기 관찰하기 위한 offline 지표로만 사용한다. `fleiss-kappa.py`는 `--offline` 플래그로 kappa 계산을 옵트인한다.

### Fleiss kappa 정의

Fleiss 1971의 chance-corrected agreement 지표. N명의 판정자가 범주형 verdict(CONFIRMED_ISSUE / NOT_AN_ISSUE / NEEDS_MORE_INFO)를 내릴 때 agreement 수준을 측정한다.

- 공식: κ = (P̄ - P̄ₑ) / (1 - P̄ₑ)
  - P̄: 관측된 쌍별 agreement의 평균
  - P̄ₑ: 기대(우연) 쌍별 agreement
- 해석 관례 (Landis & Koch 1977):
  - `κ ≥ 0.8` almost perfect
  - `0.6 ≤ κ < 0.8` substantial
  - `0.4 ≤ κ < 0.6` moderate
  - `0.2 ≤ κ < 0.4` fair
  - `κ < 0.2` slight/poor

### Offline threshold 참고값 (문서-코드 수동 동기화 계약)

배포 후 관찰 목적으로 참고할 threshold. 실시간 분기에는 사용하지 않는다. 다른 문서가 숫자를 재서술하지 말고 여기를 링크한다.

- `STABLE_MIN = 0.6`: substantial 이상 agreement. 이 이상이면 Arbiter 판정이 안정적이라고 간주.
- `ESCALATE_MIN = 0.4`: moderate 이하 agreement. 이 미만이면 Arbiter rubric/프롬프트 재검토가 필요하다는 신호.

**중요**: 이 문서는 다른 **문서**에 대해서는 single source이지만, 런타임은 `fleiss-kappa.py` 상단 상수(`STABLE_MIN`, `ESCALATE_MIN`)를 실제로 사용한다. 따라서 문서와 스크립트 사이에는 **기계적 동기화 장치 없는 manual sync contract**다. 값 조정 시 이 문서와 `modules/shared/programs/claude/files/scripts/fleiss-kappa.py`의 상수를 반드시 함께 수정한다. 향후 attrset/JSON에서 생성하는 기계 SSOT는 Phase 2 확장으로 검토.

### Harness runtime requirements

`fleiss-kappa.py`는 Python3 표준 라이브러리만 사용한다 (`json`, `argparse`, `pathlib`, `re`, `collections`, `sys`).

- **NixOS**: `pkgs.python3`가 선언적으로 프로비저닝된다 (`modules/shared/programs/shell/nixos.nix`).
- **macOS**: system python3(`/usr/bin/python3`, Xcode Command Line Tools에 포함)를 사용한다. nix-darwin은 Command Line Tools를 전제로 하므로 실질적으로 보장된다. Homebrew python이 있으면 PATH 순서에 따라 그쪽이 우선한다.

최소 Python 3.9 (표준 라이브러리 타입 힌트 사용).

## 독립 판정 설계 원칙

N=3 재판정이 의미 있는 신호를 내려면 아래 원칙을 따라야 한다. 세부 실행 계약은 [`arbiter-scaling.md`](arbiter-scaling.md) 참조.

1. **Independence** (Wang et al. 2022 "Self-Consistency"): N=3 판정은 완전 독립 process. 이전 판정 transcript 공유 금지. 각 Arbiter는 동일 입력에 대해 fresh subagent/process로 실행.
2. **Order canonicalization** (Wang et al. 2024 "Not Fair Evaluators"): finding 제시 순서와 evidence 배치를 매 run 고정하거나 랜덤화하여 position bias를 제어.
3. **Judge diversity** (Verga et al. 2024 "Replacing Judges with Juries"): v1은 동일 모델 N=3로 시작. heterogeneous judge panel은 후속 실험 영역.
4. **Prompt robustness** (POSIX 2024): 동일 finding을 paraphrase/축 순서 swap한 변형으로 재판정하면 prompt-induced drift를 측정할 수 있다. v1은 동일 프롬프트 N=3.
5. **Cost constraint** (Jung et al. 2024 "Trust or Escalate"): 모든 finding에 N=3 적용은 API 비용 3배. 애매한 finding에만 selective 적용 (위 트리거 OR 3조건).

## Non-goals

- **v1 실시간 kappa threshold 분기**: kappa는 offline 관찰 전용. v1 실시간 분기는 vote-shape만 사용. 실측 보정은 post-deploy Phase 2에서 별도 이슈로.
- **Heterogeneous jury panel**: 서로 다른 모델 계열로 N=3 구성하는 PoLL 실험은 후속 과제로 deferral.
- **Fleiss kappa 외 metric**: Cohen's kappa(2인 판정 고전), Krippendorff's alpha(일반) 등은 v1 범위 아님.
- **Arbiter prompt 자체 변경**: rubric 문구 최적화, Few-shot 추가는 본 문서가 정의하는 정책 영역 밖의 별도 트랙.

## 참조 문헌

- Fleiss 1971, "Measuring Nominal Scale Agreement among Many Raters" — [DOI](https://doi.org/10.1037/h0031619)
- Landis & Koch 1977, Biometrics — kappa 해석 관례
- Wang et al. 2022, "Self-Consistency" — [OpenReview](https://openreview.net/forum?id=1PL1NIMMrw)
- Wang et al. 2024, "Not Fair Evaluators" — [ACL](https://aclanthology.org/2024.acl-long.511/)
- Shankar et al. 2024, "Who Validates the Validators?" — [arXiv:2404.12272](https://arxiv.org/abs/2404.12272)
- Verga et al. 2024, "Replacing Judges with Juries (PoLL)" — [arXiv:2404.18796](https://arxiv.org/abs/2404.18796)
- Jung et al. 2024, "Trust or Escalate" — [arXiv:2407.18370](https://arxiv.org/abs/2407.18370)
- Haldar & Hockenmaier 2025, "Rating Roulette" — [ACL](https://aclanthology.org/2025.findings-emnlp.1361/)
- POSIX 2024 "Prompt Sensitivity Index" — [ACL](https://aclanthology.org/2024.findings-emnlp.852/)
