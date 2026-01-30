---
name: managing-tmux
description: |
  This skill should be used when the user customizes tmux keybindings,
  prefix key, session management, or asks about pane notepad, tmux plugins,
  tmux-resurrect, session save/restore, tmux.conf configuration.
---
# tmux 설정

터미널 멀티플렉서 tmux 설정 및 단축키 가이드입니다.

## 주요 설정 파일

| 파일 | 용도 |
|------|------|
| `modules/shared/programs/tmux/default.nix` | Home Manager tmux 모듈 (플러그인 포함) |
| `modules/shared/programs/tmux/files/tmux.conf` | tmux 설정 파일 |
| `modules/shared/programs/tmux/files/scripts/` | Pane Notepad 스크립트들 |

### 스크립트 목록

| 스크립트 | 용도 |
|----------|------|
| `pane-note.sh` | 노트 생성/편집/관리 |
| `pane-link.sh` | 통합 검색 (fzf/rg 모드 전환, 노트 연결/열기) |
| `pane-helpers.sh` | 통합 헬퍼 (목록, 검색, 포맷팅, fzf transform) |
| `pane-tag.sh` | 태그 수정 (두 단계 UI) |
| `pane-restore.sh` | 휴지통/아카이브에서 노트 복원 |
| `save-pane-vars.sh` | tmux-resurrect용 pane 변수 저장 |
| `restore-pane-vars.sh` | tmux-resurrect용 pane 변수 복원 |
| `smoke-test.sh` | 기능 검증 테스트 |

## 주요 Nix 옵션 (`programs.tmux`)

`default.nix`에서 Home Manager 내장 옵션을 활용하여 기본 설정을 선언적으로 관리합니다:

| 옵션 | 값 | 설명 |
|------|-----|------|
| `terminal` | `"tmux-256color"` | 기본 터미널 타입 |
| `mouse` | `true` | 마우스 지원 |
| `historyLimit` | `50000` | 스크롤백 히스토리 |
| `escapeTime` | `10` | Escape 키 지연 (ms) |
| `baseIndex` | `1` | 창 번호 시작 |
| `keyMode` | `"vi"` | copy-mode에서 vi 키바인딩 |
| `focusEvents` | `true` | Neovim autoread 지원 |

## 플러그인

| 플러그인 | 용도 |
|----------|------|
| tmux-resurrect | 세션 저장/복원 (pane 변수 포함) |
| tmux-continuum | 15분 간격 자동 저장 + 서버 시작 시 자동 복원 |
| tmux-yank | 시스템 클립보드 연동 (copy-mode) |
| tmux-thumbs | 화면에서 URL/경로/해시 등을 힌트로 선택하여 tmux buffer에 복사 |

## Pane Notepad 구조

### 폴더 구조

```
~/.tmux/pane-notes/
├── {repo}/              # Git 저장소 이름 (예: nixos-config)
│   └── {title}.md       # 노트 파일
├── _archive/            # 아카이브된 노트
└── _trash/              # 삭제된 노트
```

### YAML Frontmatter

각 노트 파일은 YAML frontmatter로 메타데이터를 관리합니다:

```yaml
---
title: 노트 제목
tags: [버그, 기능]
created: 2026-01-25
repo: nixos-config
---
```

### 태그 시스템

- 기본 태그: 버그, 기능, 리팩토링, 테스트, 문서
- 기존 노트에서 동적으로 태그 수집
- 노트 생성 시 태그 선택 (Tab으로 여러 개 선택)
- 커스텀 태그 입력 가능 (쉼표로 구분, 예: `긴급,중요`)

### 링크 파일

웹사이트 링크(URL)는 agenix로 암호화되어 관리됩니다:
- 암호화 파일: `secrets/pane-note-links.age`
- 복호화 위치: `~/.config/pane-note/links.txt`
- 설정: `modules/shared/programs/secrets/default.nix`

### 디버그

모든 스크립트에 `debug()` 함수가 내장되어 있습니다. `TMUX_NOTE_DEBUG=1` 환경변수로 활성화:

```bash
TMUX_NOTE_DEBUG=1 ~/.tmux/scripts/pane-note.sh edit
```

### 테스트

smoke-test 스크립트로 기능 검증:
```bash
~/.tmux/scripts/smoke-test.sh
```

## 레퍼런스

- 단축키 가이드: [references/shortcuts.md](references/shortcuts.md)
- 트러블슈팅: [references/troubleshooting.md](references/troubleshooting.md)
