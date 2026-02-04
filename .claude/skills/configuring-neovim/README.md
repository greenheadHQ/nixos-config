# Neovim (LazyVim) 가이드

> LazyVim 배포판 기반 Neovim 설정. Vim 기초는 `vimtutor` 참고. 키를 모르겠으면 **Space** 누르고 which-key 팝업 확인.

## 목차

- [실전 콤보](#실전-콤보)
- [LazyVim 핵심 키맵](#lazyvim-핵심-키맵)
- [Surround 치트시트](#surround-치트시트)
- [Case 전환 (vim-abolish)](#case-전환-vim-abolish)
- [플러그인 관리](#플러그인-관리)
- [트러블슈팅](references/troubleshooting.md)

---

## 실전 콤보

### 대소문자 전환

```
gUiw      단어를 대문자로         hello → HELLO
guiw      단어를 소문자로         HELLO → hello
```

### HTML/JSX 태그 작업

```
cit       태그 안 내용 변경     <div>여기를 바꿈</div>
dit       태그 안 내용 삭제     <div></div>
dat       태그 전체 삭제        태그 포함해서 통째로 제거
vit       태그 안 내용 선택     Visual 모드로 범위 확인
vat       태그 전체 선택        여는 태그 ~ 닫는 태그
```

### 검색 + 반복 편집 (세미 수동 치환)

```
*         커서 위 단어를 검색       → 모든 매칭에 하이라이트
ciw       단어를 새 단어로 변경
n         다음 매칭으로 이동
.         같은 변경 반복             → 바꾸고 싶은 곳에서만 . 누르기
```

> `:%s/old/new/g` (전체 치환)보다 **선택적으로 바꿀 때** 유용. `n`으로 이동하면서 바꿀 곳에서만 `.`을 누르면 된다.

### 자주 쓰는 콤보

```
ciw       단어 전체 변경 (커서 위치 무관)
ci"       "" 안 내용 변경            const name = "여기를 바꿈"
ci(       () 안 내용 변경            함수 인자 교체
xp        두 글자 순서 바꾸기        ab → ba
J         현재 줄과 다음 줄 합치기
vip       문단(paragraph) 선택       빈 줄로 구분된 블록
>ip       문단 들여쓰기
```

> **`ciw` vs `cw`**: `cw`는 커서~단어 끝만 바꿈. `ciw`는 커서가 단어 중간에 있어도 **단어 전체**를 바꿈.

### 줄 끝/처음까지 조작

```
C         커서~줄 끝 변경       (= c$)  줄 뒷부분만 새로 쓸 때
D         커서~줄 끝 삭제       (= d$)
Y         줄 전체 복사          (= yy)
S         줄 전체 변경          (= cc)  줄을 통째로 새로 쓸 때
```

### 선택 → 일괄 처리

```
ggVG      파일 전체 선택         (gg 맨위 → V 줄선택 → G 맨아래)
ggyG      파일 전체 복사
ggdG      파일 전체 삭제
```

---

## LazyVim 핵심 키맵

> `<leader>` = **Space 키**. which-key 팝업으로 모든 키 확인 가능.

### 파일/검색

| 키 | 동작 | VS Code 대응 |
|----|------|-------------|
| `<leader>ff` | 파일 이름으로 검색 | `Cmd+P` |
| `<leader>fg` | Git 파일 찾기 | - |
| `<leader>/` | 텍스트 검색 (grep) | `Cmd+Shift+F` |
| `<leader>fb` | 열린 버퍼 목록 | 탭 전환 |
| `<leader>fr` | 최근 파일 목록 | Recent Files |
| `<leader>e` | 파일 탐색기 토글 | Explorer 패널 |

### 코드 탐색 (LSP)

| 키 | 동작 | VS Code 대응 |
|----|------|-------------|
| `gd` | 정의로 이동 | `F12` / `Cmd+Click` |
| `gr` | 참조 찾기 | `Shift+F12` |
| `K` | 호버 문서 | 마우스 호버 |
| `<leader>ca` | 코드 액션 | `Cmd+.` |
| `<leader>cr` | 이름 변경 | `F2` |
| `<leader>cd` | 줄 진단 표시 | 문제 패널 |
| `]d` / `[d` | 다음/이전 진단 | |
| `<leader>cf` | 파일 포맷 | `Shift+Alt+F` |

### 편집 도구

| 키 | 동작 |
|----|------|
| `gcc` | 줄 주석 토글 |
| `gc` (Visual) | 선택 영역 주석 토글 |

### 버퍼 (탭)

| 키 | 동작 |
|----|------|
| `H` | 이전 버퍼 (왼쪽 탭) |
| `L` | 다음 버퍼 (오른쪽 탭) |
| `<leader>bd` | 현재 버퍼 닫기 |
| `<leader>bo` | 다른 버퍼 모두 닫기 |

### Git

| 키 | 동작 |
|----|------|
| `<leader>gg` | lazygit 열기 |

### 커스텀 키맵

| 키 | 동작 | 이유 |
|----|------|------|
| `jk` | Esc (Insert 모드) | iPad 소프트웨어 키보드 UX |
| `Ctrl+\` | 터미널 Normal 모드 | `:terminal`에서 탈출 |

---

## Surround 치트시트

> 플러그인: [nvim-surround](https://github.com/kylechui/nvim-surround). `ys`/`cs`/`ds` 키맵.

### 3가지 핵심 동작

| 동작 | 키 패턴 | 읽는 법 |
|------|---------|---------|
| **추가** | `ys{모션}{문자}` | **y**ou **s**urround {모션} with {문자} |
| **변경** | `cs{기존}{새것}` | **c**hange **s**urround {기존} to {새것} |
| **삭제** | `ds{문자}` | **d**elete **s**urround {문자} |

### 감싸기 (ys)

```
ysiw"    →  단어를 "" 로 감싸기       hello → "hello"
ysiw)    →  단어를 () 로 감싸기       hello → (hello)
ysiw}    →  단어를 {} 로 감싸기       hello → {hello}
ysiwt    →  태그로 감싸기 (태그명 입력) hello → <div>hello</div>
yss"     →  줄 전체를 "" 로 감싸기
```

> 닫는 괄호 `)]}` = 공백 없음, 여는 괄호 `([{` = 안쪽에 공백 추가.

### Visual 모드 감싸기 (S)

```
viw → S"   단어 선택 후 "" 로 감싸기
V → S{     줄 전체 선택 후 {} 로 감싸기
```

### 변경 (cs)

```
cs"'     →  " → '
cs")     →  " → ()
cst<span> → 태그 → 다른 태그
```

### 삭제 (ds)

```
ds"      →  "" 제거
ds(      →  () 제거
dst      →  태그 제거
```

### dot repeat

nvim-surround의 모든 동작은 `.`으로 **반복 가능**하다.

---

## Case 전환 (vim-abolish)

> 플러그인: [vim-abolish](https://github.com/tpope/vim-abolish). 커서가 단어 위에 있을 때 `cr{문자}`로 case 전환.

| 키 | 변환 | 예시 |
|----|------|------|
| `crs` | snake_case | `fooBar` → `foo_bar` |
| `crm` | MixedCase (PascalCase) | `foo_bar` → `FooBar` |
| `crc` | camelCase | `foo_bar` → `fooBar` |
| `cru` | UPPER_CASE | `fooBar` → `FOO_BAR` |
| `cr-` | dash-case (kebab-case) | `fooBar` → `foo-bar` |
| `cr.` | dot.case | `fooBar` → `foo.bar` |
| `cr<space>` | space case | `fooBar` → `foo bar` |
| `crt` | Title Case | `fooBar` → `Foo Bar` |

> **실전**: React 컴포넌트명(PascalCase) ↔ 파일명(kebab-case), Python(snake_case) ↔ JS(camelCase) 전환.

---

## 플러그인 관리

```vim
:Lazy               " 플러그인 매니저 UI 열기
:Lazy update        " 모든 플러그인 최신으로 업데이트
:Lazy restore       " lazy-lock.json 기준으로 복원
:Lazy health        " 플러그인 상태 점검
```

업데이트 후 `lazy-lock.json` 변경사항을 커밋해야 다른 머신과 동기화된다.

---

## 트러블슈팅

[references/troubleshooting.md](references/troubleshooting.md) 참고.
