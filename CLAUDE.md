# nixos-config

macOS와 NixOS 개발 환경을 nix-darwin/NixOS + Home Manager로 선언적 관리하는 프로젝트

## 실행 환경 인식

이 프로젝트는 macOS(Mac)와 NixOS(MiniPC) 두 머신에서 사용됩니다.
Environment 섹션의 `Platform` 값으로 현재 실행 환경을 판별하세요:

| Platform | 현재 환경 | MiniPC 작업 | Mac 작업 |
|----------|----------|------------|---------|
| `linux` | **MiniPC** (NixOS) | 로컬 명령어 직접 실행 | `ssh mac` |
| `darwin` | **Mac** (macOS) | `ssh minipc` | 로컬 명령어 직접 실행 |

**금지**: 현재 환경의 머신에 SSH 접속 금지.
`Platform: linux`이면 이미 MiniPC — `ssh minipc` 절대 실행하지 말 것.
`Platform: darwin`이면 이미 Mac — `ssh mac` 절대 실행하지 말 것.

> 현재 NixOS 호스트는 MiniPC 1대뿐이므로 `Platform: linux` = MiniPC로 판별합니다.
> 호스트가 추가되면 `hostname` 명령으로 구분하세요.

## 핵심 명령어

| 명령어 | 설명 |
|--------|------|
| `nrs` | 설정 적용 (미리보기 + 적용) |
| `ssh minipc` | MiniPC SSH 접속 — **Mac에서만** (Platform: darwin) |
| `ssh mac` | macOS SSH 접속 — **MiniPC에서만** (Platform: linux) |

## 빌드 시 주의사항

`nrs`를 사용하세요. `darwin-rebuild`/`nixos-rebuild`를 직접 실행하지 마세요.

`nrs`가 자동으로 처리하는 것들:
- launchd agent 정리 (setupLaunchAgents 멈춤 방지, macOS)
- Hammerspoon 재시작 (macOS)

## 주요 디렉토리

| 경로 | 설명 |
|------|------|
| `libraries/constants.nix` | 전역 상수 (IP, 경로, SSH 키, UID 등) - 단일 소스 |
| `libraries/packages.nix` | 공통 패키지 (shared/darwinOnly/nixosOnly) |
| `modules/darwin/` | macOS 전용 설정 |
| `modules/nixos/` | NixOS 전용 설정 |

## 상수 참조

하드코딩된 IP, 경로, SSH 키, UID 등을 추가/변경할 때는 반드시 `libraries/constants.nix`를 수정하세요.

## 스킬 문서 불일치 시 행동 원칙

스킬 문서에 기재된 CLI 명령/플래그를 실행했는데 에러가 발생하면:

1. 해당 명령의 `--help`를 실행해 실제 지원 플래그를 확인한다.
2. 문서 내용과 실제 CLI 동작의 차이를 정리한다.
3. 사용자에게 즉시 알린다:
   - 에러 내용
   - 문서에 기재된 내용 vs 실제 CLI `--help` 결과
   - 문서 수정이 필요한지 판단을 요청
4. 자의적으로 문서를 우회하거나 무시하고 진행하지 않는다.

> CLI `--help` 출력이 스킬 문서보다 항상 우선하는 진실 원천이다.
