# Pane Notepad 상세

## 스크립트 목록

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

## 태그 시스템

- 기본 태그: 버그, 기능, 리팩토링, 테스트, 문서
- 기존 노트에서 동적으로 태그 수집
- 노트 생성 시 태그 선택 (Tab으로 여러 개 선택)
- 커스텀 태그 입력 가능 (쉼표로 구분, 예: `긴급,중요`)

## 링크 파일

웹사이트 링크(URL)는 agenix로 암호화되어 관리됩니다:
- 암호화 파일: `secrets/pane-note-links.age`
- 복호화 위치: `~/.config/pane-note/links.txt`
- 설정: `modules/shared/programs/secrets/default.nix`

## 디버그

모든 스크립트에 `debug()` 함수가 내장되어 있습니다. `TMUX_NOTE_DEBUG=1` 환경변수로 활성화:

```bash
TMUX_NOTE_DEBUG=1 ~/.tmux/scripts/pane-note.sh edit
```

## 테스트

smoke-test 스크립트로 기능 검증:
```bash
~/.tmux/scripts/smoke-test.sh
```
