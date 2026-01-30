# tmux 단축키 가이드

tmux 터미널 멀티플렉서의 단축키와 기능을 정리합니다.

## 목차

- [처음 시작 (필수 5가지)](#처음-시작-필수-5가지)
- [기본 단축키](#기본-단축키)
- [세션 저장/복원 (tmux-resurrect)](#세션-저장복원-tmux-resurrect)
- [텍스트 복사 (tmux-thumbs)](#텍스트-복사-tmux-thumbs)
- [Pane Notepad 기능](#pane-notepad-기능)
- [Pane 상태 표시](#pane-상태-표시)
- [세션 관리](#세션-관리)

---

## 처음 시작 (필수 5가지)

SSH 접속 시 tmux `main` 세션에 자동 연결됩니다 (NixOS 서버). 아래 5가지만 알면 기본 사용이 가능합니다.

| 단축키             | 기능                                           |
| ------------------ | ---------------------------------------------- |
| `prefix + c`       | 새 창 만들기                                   |
| `prefix + 1-9`     | 해당 번호 창으로 이동                          |
| `prefix + d`       | tmux에서 나가기 (세션 유지, SSH 재접속 시 자동 복귀) |
| `prefix + Ctrl-s`  | 세션 저장                                      |
| `prefix + Ctrl-r`  | 세션 복원                                      |

## 기본 단축키

`modules/shared/programs/tmux/files/tmux.conf`에서 관리됩니다.

**Prefix**: `Ctrl+b`

| 단축키       | 기능                             |
| ------------ | -------------------------------- |
| `prefix + r` | 설정 리로드 (`~/.config/tmux/tmux.conf`) |
| `prefix + a` | 도움말 (사용 가능한 단축키 표시) |
| `prefix + s` | 세션 선택                        |
| `prefix + ,` | 창 이름 변경                     |
| `prefix + $` | 세션 이름 변경                   |
| `prefix + P` | Pane 제목 설정                   |

---

## 세션 저장/복원 (tmux-resurrect + tmux-continuum)

tmux-resurrect 플러그인으로 세션을 저장하고 복원할 수 있습니다.
Pane 변수(`@pane_note_path`, `@custom_pane_title`)도 식별자 기반(`session:window.pane`)으로 저장/복원됩니다.

tmux-continuum이 15분 간격으로 자동 저장하며, tmux 서버 시작 시 마지막 세션을 자동 복원합니다.

| 단축키             | 기능                        |
| ------------------ | --------------------------- |
| `prefix + Ctrl-s`  | 세션 저장 (pane 변수 포함)  |
| `prefix + Ctrl-r`  | 세션 복원                   |

**저장 위치**: `~/.local/share/tmux/resurrect/`
**Pane 변수 파일**: `~/.local/share/tmux/resurrect/pane_vars.txt` (형식: `var_type|session:window.pane|value`)

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
| `prefix + K` | 통합 검색 (노트 연결/열기)  |
| `prefix + T` | 노트 태그 수정              |
| `prefix + R` | 휴지통/아카이브에서 복원    |

**노트 저장 위치**: `~/.tmux/pane-notes/{repo}/{title}.md`

### 통합 검색 (prefix + K)

fzf와 ripgrep을 통합한 노트 검색 기능입니다.

**두 가지 검색 모드**:
- **fzf 모드**: 제목/태그 퍼지 필터링 (기본)
- **rg 모드**: ripgrep으로 노트 내용 검색

**프롬프트 형식**:
```
Link note [fzf/created]>   # fzf 모드, 생성일 정렬
Link note [rg/mtime]>      # rg 모드, 수정일 정렬
Link note [프로젝트명]>     # 프로젝트 필터 적용
```

**fzf 내부 단축키**:

| 단축키       | 기능                                |
| ------------ | ----------------------------------- |
| `Enter`      | 선택한 노트를 pane에 연결           |
| `Ctrl-/`     | fzf ↔ rg 모드 전환                  |
| `Ctrl-O`     | 노트 열기만 (연결 안 함)            |
| `Ctrl-P`     | 현재 프로젝트 노트로 필터링         |
| `Ctrl-A`     | 모든 노트 보기                      |
| `Ctrl-S`     | 정렬 토글 (생성일 ↔ 수정일)         |
| `Ctrl-D`     | 휴지통으로 보내기 (`_trash/`)       |
| `Ctrl-X`     | 아카이브로 보내기 (`_archive/`)     |
| `Tab`        | 미리보기 아래로 스크롤              |
| `Shift-Tab`  | 미리보기 위로 스크롤                |
| `ESC`        | 취소                                |

**rg 모드 특수 기능**:
- `#태그명` 입력 시 태그 필터링 (예: `#버그`)
- 선택 시 첫 매칭 라인으로 에디터 점프

**표시 형식**:
```
YYYY-MM-DD | [repo] 제목 #태그1 #태그2
YYYY-MM-DD | [repo] 제목 (3 matches)     # rg 모드에서 매칭 수 표시
```

- 태그는 밝은 주황색으로 표시됨

### 태그 수정 (prefix + T)

두 단계 UI로 태그를 수정합니다:

1. **1단계**: 현재 태그 중 제거할 것 선택 (Tab으로 선택, Enter로 다음)
2. **2단계**: 추가할 태그 선택 (Tab으로 선택, 직접 입력도 가능)

**특징**:
- 현재 태그가 기본 유지됨 (명시적으로 제거해야 삭제)
- ESC로 취소 가능

### 노트 복원 (prefix + R)

휴지통(`_trash/`) 또는 아카이브(`_archive/`)에서 노트를 복원합니다.

**동작 순서**:
1. 소스 선택 (휴지통 vs 아카이브)
2. 복원할 노트 선택
3. 복원 위치 선택 (원래 프로젝트 자동 감지)

### 태그 선택 (노트 생성 시)

| 단축키       | 기능                                |
| ------------ | ----------------------------------- |
| `Tab`        | 기존 태그 선택/해제                 |
| `Enter`      | 선택 완료                           |
| `ESC`        | 건너뛰기 (태그 없음)                |
| 프롬프트     | 새 태그 직접 입력 (쉼표로 여러 개)  |

---

## Pane 상태 표시

```
[ main]: my-task 🗒️
```

- Git 브랜치 표시 (`main`)
- 커스텀 pane 제목 (`my-task`)
- 노트 아이콘 - 노트에 내용이 있을 때 표시

---

## 텍스트 복사 (tmux-thumbs)

`prefix + F`로 화면의 URL, 파일 경로, git hash, IP 등을 자동 인식하여 힌트로 표시합니다. 힌트 키를 누르면 tmux buffer에 복사됩니다. OSC 52 미지원 터미널(Termius 등)에서 특히 유용합니다.

| 단축키       | 기능                                       |
| ------------ | ------------------------------------------ |
| `prefix + F` | 화면에서 패턴 인식 → 힌트 표시             |
| 소문자 힌트  | 선택한 텍스트를 tmux buffer에 복사          |
| 대문자 힌트  | 선택한 텍스트를 tmux buffer에 복사 (upcase) |
| `prefix + ]` | tmux buffer 붙여넣기                        |

**설정**: `modules/shared/programs/tmux/default.nix`의 `tmux-thumbs` 플러그인

---

## Copy-mode (vi 키바인딩)

`keyMode = "vi"`가 설정되어 있어 copy-mode에서 vi 스타일 키바인딩을 사용합니다.
tmux-yank 플러그인이 시스템 클립보드와 연동합니다.

| 단축키 | 기능 |
| ------ | ---- |
| `v` | 선택 시작 |
| `y` | 선택 영역 복사 (클립보드) |
| `q` | copy-mode 종료 |

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
