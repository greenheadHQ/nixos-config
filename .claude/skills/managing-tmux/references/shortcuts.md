# tmux 단축키 가이드

tmux 터미널 멀티플렉서의 단축키와 기능을 정리합니다.

## 목차

- [기본 단축키](#기본-단축키)
- [세션 저장/복원 (tmux-resurrect)](#세션-저장복원-tmux-resurrect)
- [Pane Notepad 기능](#pane-notepad-기능)
- [Pane 상태 표시](#pane-상태-표시)
- [세션 관리](#세션-관리)

---

## 기본 단축키

`modules/shared/programs/tmux/files/tmux.conf`에서 관리됩니다.

**Prefix**: `Ctrl+b`

| 단축키       | 기능                             |
| ------------ | -------------------------------- |
| `prefix + r` | 설정 리로드                      |
| `prefix + a` | 도움말 (사용 가능한 단축키 표시) |
| `prefix + s` | 세션 선택                        |
| `prefix + ,` | 창 이름 변경                     |
| `prefix + $` | 세션 이름 변경                   |
| `prefix + P` | Pane 제목 설정                   |

---

## 세션 저장/복원 (tmux-resurrect)

tmux-resurrect 플러그인으로 세션을 저장하고 복원할 수 있습니다.
Pane 변수(`@pane_note_path`, `@custom_pane_title`)도 함께 저장/복원됩니다.

| 단축키             | 기능                        |
| ------------------ | --------------------------- |
| `prefix + Ctrl-s`  | 세션 저장 (pane 변수 포함)  |
| `prefix + Ctrl-r`  | 세션 복원                   |

**저장 위치**: `~/.local/share/tmux/resurrect/`

---

## Pane Notepad 기능

각 pane마다 독립적인 노트를 관리할 수 있습니다.

### 기본 단축키

| 단축키       | 기능                        |
| ------------ | --------------------------- |
| `prefix + n` | 노트 편집                   |
| `prefix + y` | 클립보드 내용을 노트에 추가 |
| `prefix + v` | 노트 읽기 전용 보기         |
| `prefix + u` | 노트의 URL 열기             |
| `prefix + N` | 새 노트 생성 (제목 입력)    |
| `prefix + K` | 기존 노트 연결 (Link note)  |
| `prefix + V` | 노트 미리보기 (Peek note)   |
| `prefix + T` | 노트 태그 수정              |
| `prefix + S` | 노트 내용 검색 (ripgrep)    |

**노트 저장 위치**: `~/.tmux/pane-notes/{repo}/{title}.md`

### fzf 내부 단축키 (Link/Peek note)

| 단축키       | 기능                                |
| ------------ | ----------------------------------- |
| `Tab`        | 미리보기 아래로 스크롤              |
| `Shift-Tab`  | 미리보기 위로 스크롤                |
| `ctrl-p`     | 현재 프로젝트 노트로 필터링         |
| `ctrl-a`     | 모든 노트 보기                      |
| `ctrl-d`     | 휴지통으로 보내기 (`_trash/`)       |
| `ctrl-x`     | 아카이브로 보내기 (`_archive/`)     |

### 태그 선택 (노트 생성 시)

| 단축키       | 기능                                |
| ------------ | ----------------------------------- |
| `Tab`        | 기존 태그 선택/해제                 |
| `Enter`      | 선택 완료                           |
| `ESC`        | 건너뛰기 (태그 없음)                |
| 프롬프트     | 새 태그 직접 입력 (쉼표로 여러 개)  |

### 목록 표시 형식

```
MM-DD | [repo] 제목 #태그1 #태그2
```

- 태그는 밝은 주황색으로 표시됨

---

## Pane 상태 표시

```
[ main]: my-task 📝
```

- Git 브랜치 표시 (`main`)
- 커스텀 pane 제목 (`my-task`)
- 노트 아이콘 - 노트에 내용이 있을 때 표시

---

## 세션 관리

```bash
# 새 세션 생성
tmux new -s session-name

# 세션 목록
tmux ls

# 세션 연결
tmux attach -t session-name

# 세션 분리 (tmux 내에서)
prefix + d
```
