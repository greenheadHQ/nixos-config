# tmux 트러블슈팅

## 목차

- [tmux-resurrect 복원 시 pane 변수가 복원되지 않음](#tmux-resurrect-복원-시-pane-변수가-복원되지-않음)
- [pane-peek.sh에서 선택한 노트가 빈 문서로 열림](#pane-peeksh에서-선택한-노트가-빈-문서로-열림)
- [태그 선택 시 잘못된 값 표시 (경로, URL 등)](#태그-선택-시-잘못된-값-표시-경로-url-등)
- [노트 생성 시 태그 선택이 저장되지 않음](#노트-생성-시-태그-선택이-저장되지-않음)

---

## tmux-resurrect 복원 시 pane 변수가 복원되지 않음

### 증상

- `prefix + Ctrl-r`로 세션 복원 후 pane 제목(`@custom_pane_title`)은 복원되지만
- 노트 연결(`@pane_note_path`)이 복원되지 않음 (노트 아이콘 🗒️ 안 보임)
- 두 번째 `prefix + Ctrl-r`을 누르면 복원됨

### 원인

`pane-focus-in` hook이 `post-restore-all` hook보다 먼저 실행됨:

1. tmux-resurrect가 pane 복원
2. `pane-focus-in` hook 실행 → `@pane_note_path`를 기본값으로 설정
3. `post-restore-all` hook 실행 → 올바른 값으로 복원 시도
4. 하지만 2번에서 이미 값이 설정되어 있어 무시됨

### 해결

`pane-focus-in` hook 제거 (tmux.conf):

```bash
# 제거됨 (복원 방해)
# set-hook -g pane-focus-in 'run-shell "$HOME/.tmux/scripts/pane-note.sh ensure-var"'
```

`@pane_note_path`는 노트 명령어(`prefix + n`, `prefix + N` 등) 사용 시 자동 설정됨.

### 관련 파일

- `modules/shared/programs/tmux/files/tmux.conf`
- `modules/shared/programs/tmux/files/scripts/restore-pane-vars.sh`
- `modules/shared/programs/tmux/files/scripts/save-pane-vars.sh`

---

## pane-peek.sh에서 선택한 노트가 빈 문서로 열림

### 증상

`prefix + V`로 노트 선택 후 에디터에서 빈 파일이 열림.

### 원인

`fzf-tmux`가 별도 프로세스로 실행되어 `cd "$NOTES_DIR"` 컨텍스트가 유지되지 않음.

### 해결

`fzf-tmux` 대신 `tmux display-popup` + `fzf` 조합 사용:

```bash
tmux display-popup -E -w 80% -h 80% \
  "cd \"$NOTES_DIR\" 2>/dev/null || exit 0;
   sel=\$(ls -1t *.md | fzf --prompt='Peek note> ' ...) || exit 0;
   \"\${EDITOR:-vim}\" \"$NOTES_DIR/\$sel\""
```

### 관련 파일

- `modules/shared/programs/tmux/files/scripts/pane-peek.sh`

---

## 태그 선택 시 잘못된 값 표시 (경로, URL 등)

### 증상

`prefix + N`으로 노트 생성 시 태그 팔레트에 파일 경로나 URL 같은 이상한 값이 표시됨.

### 원인

YAML frontmatter가 없는 기존 flat 구조 노트(`~/.tmux/pane-notes/*.md`)에서 yq가 예상치 못한 값을 반환함.

### 해결

태그 값 자체를 검증하여 필터링:

```bash
find "$NOTES_DIR" -name "*.md" ! -path "*/_archive/*" ! -path "*/_trash/*" \
  -exec yq -r 'select(.tags) | .tags[]' {} \; 2>/dev/null \
  | grep -vE '^(/|https?://|[[:space:]]*$)' \
  | awk 'length <= 30' \
  | sort -u
```

필터링 기준:
- `select(.tags)`: tags 필드가 있는 파일만 처리
- 경로(`/`로 시작) 제외
- URL(`http://`, `https://`) 제외
- 빈 값 제외
- 30자 초과 제외

### 관련 파일

- `modules/shared/programs/tmux/files/scripts/pane-note.sh`
- `modules/shared/programs/tmux/files/scripts/pane-tag.sh`

---

## 노트 생성 시 태그 선택이 저장되지 않음

### 증상

`prefix + N`으로 노트 생성하고 태그를 선택했는데, 생성된 노트에 태그가 비어있음.

### 원인

`tmux display-popup`은 내부 명령의 stdout을 캡처하지 않음.

### 해결

임시 파일을 통해 fzf 선택 결과를 전달:

```bash
tmp_file=$(mktemp)
tmux display-popup -E -w 90% -h 50% \
  "echo '$ALL_TAGS' | fzf --multi ... > '$tmp_file'" 2>/dev/null || true
selected_tags=$(tr '\n' ',' < "$tmp_file" | sed 's/,$//')
rm -f "$tmp_file"
```

### 관련 파일

- `modules/shared/programs/tmux/files/scripts/pane-note.sh`
