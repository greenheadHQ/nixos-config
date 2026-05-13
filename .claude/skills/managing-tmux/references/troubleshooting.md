# tmux 트러블슈팅

## 목차

- [tmux-resurrect 복원 시 pane 변수가 복원되지 않음](#tmux-resurrect-복원-시-pane-변수가-복원되지-않음)
- [태그 선택 시 잘못된 값 표시 (경로, URL 등)](#태그-선택-시-잘못된-값-표시-경로-url-등)
- [노트 생성 시 태그 선택이 저장되지 않음](#노트-생성-시-태그-선택이-저장되지-않음)
- [yq가 마크다운 frontmatter를 제대로 파싱하지 못함](#yq가-마크다운-frontmatter를-제대로-파싱하지-못함)
- [빈 tags 배열일 때 날짜/태그 파싱 오류](#빈-tags-배열일-때-날짜태그-파싱-오류)
- [yq -i로 frontmatter 수정 시 파일 구조 손상](#yq--i로-frontmatter-수정-시-파일-구조-손상)
- [한글 태그 sort 시 에러 발생](#한글-태그-sort-시-에러-발생)
- [display-popup에서 에디터/뷰어 command not found](#display-popup에서-에디터뷰어-command-not-found)

---

## tmux-resurrect 복원 시 pane 변수가 복원되지 않음

### 증상

- `prefix + Ctrl-r`로 세션 복원 후 pane 제목(`@custom_pane_title`)은 복원되지만
- 노트 연결(`@pane_note_path`)이 복원되지 않음 (노트 아이콘 🗒️ 안 보임)
- 두 번째 `prefix + Ctrl-r`을 누르면 복원됨

### 원인 (과거)

`pane-focus-in` hook이 `post-restore-all` hook보다 먼저 실행되어 복원된 값을 덮어씀.

### 해결 (2단계)

1차: `pane-focus-in` hook 제거

```bash
# 제거됨 (복원 방해)
# set-hook -g pane-focus-in 'run-shell "$HOME/.tmux/scripts/pane-note.sh ensure-var"'
```

2차: 순서 기반(line_num) → 식별자 기반(`session:window.pane`) 매핑으로 전환

구 형식: `var_type|line_num|value` — pane 순서가 바뀌면 잘못된 pane에 복원됨
신 형식: `var_type|session:window.pane|value` — 순서 무관하게 정확한 pane에 복원

```bash
# save: 식별자로 저장
ident="$(tmux display-message -t "$pane_id" -p '#{session_name}:#{window_index}.#{pane_index}')"
echo "note_path|$ident|$note_path" >> "$VARS_FILE"

# restore: pane_map을 한 번만 구성하여 O(N) 매칭
pane_map=$(tmux list-panes -a -F '#{session_name}:#{window_index}.#{pane_index} #{pane_id}')
target_pane=$(printf '%s\n' "$pane_map" | awk -v id="$ident" '$1 == id { print $2 }')
```

한계: tmux-resurrect가 동명 세션 충돌 시 이름을 변경(`main` → `main_0`)하면 해당 pane의 변수 복원이 건너뛰어질 수 있음.

### 관련 파일

- `modules/shared/programs/tmux/files/tmux.conf`
- `modules/shared/programs/tmux/files/scripts/restore-pane-vars.sh`
- `modules/shared/programs/tmux/files/scripts/save-pane-vars.sh`

---

## 태그 선택 시 잘못된 값 표시 (경로, URL 등)

### 증상

`prefix + N`으로 노트 생성 시 태그 팔레트에 파일 경로나 URL 같은 이상한 값이 표시됨.

### 원인

YAML frontmatter가 없는 기존 flat 구조 노트(`~/.tmux/pane-notes/*.md`)에서 yq가 예상치 못한 값을 반환함.

### 해결

태그 값 자체를 검증하여 필터링 (`{} +`로 배치 실행):

```bash
find "$NOTES_DIR" -name "*.md" ! -path "*/_archive/*" ! -path "*/_trash/*" \
  -exec yq --front-matter=extract -r 'select(.tags) | .tags[]' {} + 2>/dev/null \
  | grep -vE '^(/|https?://|[[:space:]]*$)' \
  | awk 'length <= 30' \
  | LC_ALL=C sort -u
```

필터링 기준:
- `--front-matter=extract`: 마크다운 frontmatter만 추출
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

---

## yq가 마크다운 frontmatter를 제대로 파싱하지 못함

### 증상

노트 목록에서 날짜/태그가 표시되지 않거나, 태그 수집이 안 됨.

### 원인

yq가 마크다운 파일을 직접 읽을 때 frontmatter 이후의 본문도 YAML로 파싱하려고 시도함.
첫 번째 문서(frontmatter)는 잘 파싱되지만 두 번째 문서(마크다운 본문)에서 에러 발생.
에러로 인해 exit code가 1이 되어 조건문이 실패하거나 결과가 비어있음.

### 해결

읽기 전용 작업: `--front-matter=extract` 사용

```bash
# 문제가 되는 코드
yq -r '.title' "$file"  # exit code: 1 (본문 파싱 에러)

# 해결된 코드
yq --front-matter=extract -r '.title' "$file"  # exit code: 0
```

수정 작업: `--front-matter=process` 사용

```bash
# 문제가 되는 코드
yq -i '.tags = ["new"]' "$file"  # 파일 구조 손상

# 해결된 코드
yq --front-matter=process -i '.tags = ["new"]' "$file"  # frontmatter만 수정, 본문 유지
```

### 적용해야 하는 스크립트

모든 yq 호출에 적절한 `--front-matter` 옵션 필요:

| 스크립트 | 작업 | 옵션 |
|---------|------|------|
| `pane-helpers.sh` | 읽기 | `--front-matter=extract` |
| `pane-note.sh` | 읽기 | `--front-matter=extract` |
| `pane-tag.sh` | 읽기 | `--front-matter=extract` |
| `pane-tag.sh` | 수정 | `--front-matter=process` |
| `pane-restore.sh` | 읽기 | `--front-matter=extract` |
| `smoke-test.sh` | 읽기 | `--front-matter=extract` |

### 관련 파일

- `modules/shared/programs/tmux/files/scripts/pane-helpers.sh`
- `modules/shared/programs/tmux/files/scripts/pane-note.sh`
- `modules/shared/programs/tmux/files/scripts/pane-tag.sh`
- `modules/shared/programs/tmux/files/scripts/pane-restore.sh`
- `modules/shared/programs/tmux/files/scripts/smoke-test.sh`

---

## 빈 tags 배열일 때 날짜/태그 파싱 오류

### 증상

`tags: []`인 노트에서:
- 날짜가 `----/--/--`로 표시됨
- 태그 위치에 날짜(`#2026-01-25`)가 표시됨

### 원인

bash의 `read` 명령어가 연속된 탭(빈 필드)을 건너뛰는 문제.

yq 출력: `title<TAB><TAB>created` (tags가 빈 문자열)

```bash
# 문제가 되는 코드
IFS=$'\t' read -r title tags created <<< "$metadata"
# 결과: title=값, tags=created값, created=빈문자열

# 해결된 코드
title=$(printf '%s' "$metadata" | cut -f1)
tags=$(printf '%s' "$metadata" | cut -f2)
created=$(printf '%s' "$metadata" | cut -f3)
```

### 해결

`cut` 명령어로 각 필드를 명시적으로 추출:

```bash
if metadata=$(yq --front-matter=extract -r '[.title // "", (.tags // [] | join(" #")), .created // ""] | @tsv' "$file" 2>/dev/null); then
  title=$(printf '%s' "$metadata" | cut -f1)
  tags=$(printf '%s' "$metadata" | cut -f2)
  created=$(printf '%s' "$metadata" | cut -f3)
fi
```

### 관련 파일

- `modules/shared/programs/tmux/files/scripts/pane-helpers.sh`

---

## yq -i로 frontmatter 수정 시 파일 구조 손상

### 증상

`pane-tag.sh`로 태그 수정 후 노트 파일 구조가 손상됨:
- frontmatter의 `---` 닫는 구분자 사라짐
- 마크다운 본문이 YAML과 섞임

### 원인

`yq -i`가 `--front-matter` 옵션 없이 마크다운 파일을 수정하면 파일 전체를 YAML로 재작성함.

### 해결

수정 작업에는 `--front-matter=process` 사용:

```bash
# 문제가 되는 코드
yq -i '.tags = ["new"]' "$file"

# 해결된 코드
yq --front-matter=process -i '.tags = ["new"]' "$file"
```

추가 주의: yq의 `split("\n")`이 줄바꿈을 제대로 처리하지 못할 수 있음. 쉼표 구분자 사용 권장:

```bash
# 줄바꿈을 쉼표로 변환
tags_csv=$(echo "$tags" | tr '\n' ',' | sed 's/,$//')
export FINAL_TAGS="$tags_csv"
yq --front-matter=process -i '.tags = (env(FINAL_TAGS) | split(",") | map(select(. != "")))' "$file"
```

### 관련 파일

- `modules/shared/programs/tmux/files/scripts/pane-tag.sh`

---

## 한글 태그 sort 시 에러 발생

### 증상

태그 수집 시 `sort -u`에서 에러 메시지:
```
sort: string comparison failed: Invalid argument
sort: Set LC_ALL='C' to work around the problem.
sort: The strings compared were '기능' and '문서'.
```

결과적으로 태그 목록이 비어있거나 일부만 표시됨.

### 원인

macOS/일부 Linux 환경에서 UTF-8 한글 문자열의 정렬 시 locale 설정 충돌.

### 해결

`sort` 명령어에 `LC_ALL=C` 환경변수 추가:

```bash
# 문제가 되는 코드
... | sort -u

# 해결된 코드
... | LC_ALL=C sort -u
```

### 관련 파일

- `modules/shared/programs/tmux/files/scripts/pane-note.sh`
- `modules/shared/programs/tmux/files/scripts/pane-tag.sh`

---

## display-popup에서 에디터/뷰어 command not found

### 증상

- `prefix + e`(노트 편집) 또는 `prefix + v`(노트 보기) 시 popup에서 `nvim: command not found`, `bat: command not found` 에러 발생
- 일반 tmux pane에서는 `nvim`, `bat` 모두 정상 동작하지만, `display-popup`에서만 실패

### 원인

`tmux display-popup -E`는 새로운 셸(`/bin/sh` 또는 기본 셸)을 시작하는데, 이 셸은 Nix 프로필(`/nix/var/nix/profiles/...`)이 PATH에 포함되지 않은 상태로 시작됨. 따라서 Nix로 설치된 `nvim`, `bat` 등의 바이너리를 찾지 못함.

기존 코드는 popup 셸 내부에서 `$EDITOR`나 `command -v`로 에디터를 찾으려 했으나, popup 셸의 불완전한 PATH 때문에 resolve에 실패함.

```bash
# 문제가 되는 코드: popup 셸의 PATH로 resolve 시도
tmux display-popup -E -w 90% -h 85% \
  "NOTE=\"$note\"; :${EDITOR:=nvim}; exec \"${EDITOR}\" \"$NOTE\""

tmux display-popup -E -w 80% -h 80% \
  "NOTE=\"$note\"; if command -v bat >/dev/null 2>&1; then bat ...; else less ...; fi"
```

### 해결

호출 측(현재 셸)에서 절대 경로로 미리 resolve한 뒤, popup에 절대 경로를 전달:

```bash
# 에디터: 현재 셸에서 절대 경로 resolve
open_popup_edit(){
  local editor_cmd
  editor_cmd="$(command -v "${EDITOR:-nvim}" 2>/dev/null \
    || command -v nvim 2>/dev/null \
    || command -v vim 2>/dev/null \
    || echo vi)"
  tmux display-popup -E -w 90% -h 85% \
    "exec '$editor_cmd' '$note'"
}

# 뷰어: 현재 셸에서 절대 경로 resolve
open_popup_view(){
  local viewer_cmd
  viewer_cmd="$(command -v bat 2>/dev/null || true)"
  if [ -n "$viewer_cmd" ]; then
    tmux display-popup -E -w 80% -h 80% \
      "'$viewer_cmd' -pp --paging=always '$note'"
  else
    tmux display-popup -E -w 80% -h 80% \
      "LESS= less -+F -+X -R '$note'"
  fi
}
```

핵심 원칙: `display-popup` 셸의 PATH에 의존하지 말고, 호출 시점에 절대 경로를 확정할 것.

### 관련 파일

- `modules/shared/programs/tmux/files/scripts/pane-note.sh`
