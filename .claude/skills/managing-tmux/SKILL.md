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

## 플러그인

| 플러그인 | 용도 |
|----------|------|
| tmux-resurrect | 세션 저장/복원 (pane 변수 포함) |

## Pane Notepad 링크 파일

웹사이트 링크(URL)는 agenix로 암호화되어 관리됩니다:
- 암호화 파일: `secrets/pane-note-links.age`
- 복호화 위치: `~/.config/pane-note/links.txt`
- 설정: `modules/shared/programs/secrets/default.nix`

## 레퍼런스

- 단축키 가이드: [references/shortcuts.md](references/shortcuts.md)
- 트러블슈팅: [references/troubleshooting.md](references/troubleshooting.md)
