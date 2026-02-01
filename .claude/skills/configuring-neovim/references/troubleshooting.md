# Neovim 트러블슈팅

## 목차

- [LSP 서버가 시작되지 않음](#lsp-서버가-시작되지-않음)
- [tree-sitter 파서 컴파일 실패](#tree-sitter-파서-컴파일-실패)
- [Mason이 여전히 활성화됨](#mason이-여전히-활성화됨)
- [lazy-lock.json 호스트 간 충돌](#lazy-lockjson-호스트-간-충돌)
- [심볼릭 링크 깨짐 (~/.config/nvim)](#심볼릭-링크-깨짐-confignvim)
- [Termius 키 제한](#termius-키-제한)
- [한국어 IME 전환](#한국어-ime-전환)
- [플러그인 업데이트](#플러그인-업데이트)
- [Nix 빌드 실패 (extraPackages)](#nix-빌드-실패-extrapackages)
- [ESLint 진단 중복](#eslint-진단-중복)
- [macOS에서 nrs 빌드가 수십 분 멈춤 (LLVM 소스 빌드)](#macos에서-nrs-빌드가-수십-분-멈춤-llvm-소스-빌드)
- [marksman이 Swift 소스 빌드를 트리거 (빌드 실패)](#marksman이-swift-소스-빌드를-트리거-빌드-실패)
- [indent-blankline setup 함수 호출 실패](#indent-blankline-setup-함수-호출-실패)
- [tree-sitter CLI 누락 (파서 컴파일 불가)](#tree-sitter-cli-누락-파서-컴파일-불가)
- [mini.surround 조직 이름 변경 경고](#minisurround-조직-이름-변경-경고)

## LSP 서버가 시작되지 않음

```bash
# 1. LSP 바이너리가 PATH에 있는지 확인
nvim -c ':!which vtsls'
nvim -c ':!which nil'

# 2. :LspInfo로 활성 서버 확인
:LspInfo

# 3. extraPackages 확인 (Nix wrapper PATH)
nvim -c ':!echo $PATH' | tr ':' '\n' | grep nix
```

**원인**: `extraPackages`는 `--suffix PATH`로 추가됨. direnv가 제공하는 도구가 우선.
프로젝트 `.envrc`가 다른 버전을 제공하면 해당 버전이 사용됨 (의도된 동작).

## tree-sitter 파서 컴파일 실패

```
Error: CC not found
```

**원인**: NixOS에서 `gcc`가 PATH에 없음.
**해결**: `extraPackages`에 `pkgs.gcc` 포함 확인.

```bash
nvim -c ':!which gcc'
:TSInstall nix  # 컴파일 테스트
```

## Mason이 여전히 활성화됨

```vim
:Mason  " 이 명령이 동작하면 비활성화 실패
```

**원인**: `disabled.lua`에서 `williamboman/mason.nvim` 사용 (잘못된 org명).
**해결**: `mason-org/mason.nvim`으로 변경.

```lua
-- lua/plugins/disabled.lua
{ "mason-org/mason.nvim", enabled = false },
{ "mason-org/mason-lspconfig.nvim", enabled = false },
```

## lazy-lock.json 호스트 간 충돌

```bash
# macOS에서 생성된 lock 파일과 NixOS에서 충돌 시
git checkout --theirs lazy-lock.json
nvim -c ':Lazy restore'  # lock 파일 기준으로 재설치
```

## 심볼릭 링크 깨짐 (~/.config/nvim)

```bash
ls -la ~/.config/nvim
# → nixos-config repo 경로로 연결되어야 함

# 깨진 경우: 기존 디렉토리가 남아있을 수 있음
rm -rf ~/.config/nvim  # 기존 디렉토리 삭제
nrs                     # Home Manager가 심볼릭 링크 재생성
```

**주의**: HM은 디렉토리 → 심볼릭 링크 자동 교체 불가. 기존 디렉토리를 수동 삭제해야 함.

## Termius 키 제한

| 문제 | 우회 |
|------|------|
| Esc 키 접근 어려움 | `jk` 매핑 (Insert 모드) |
| Ctrl 조합 불편 | leader(Space) 기반 키맵 사용 |
| OSC 52 미지원 | tmux-thumbs (`prefix+F`)로 클립보드 보완 |
| 한글 입력 깨짐 | 알려진 Termius 제한. 영문으로 입력 후 변환 |

## 한국어 IME 전환

외부 앱에서 한글을 쓰다가 Neovim으로 돌아왔을 때 Normal 모드에서 키맵이 동작하지 않는 문제.

**현재 구조** (macOS 전용, `macism` 필수):

| 레이어 | 도구 | 파일 | 역할 |
|--------|------|------|------|
| 1차 | FocusGained autocmd | `autocmds.lua` | 외부 앱 복귀 시 영문 전환 → 내장 명령(dd, yy 등) 정상 동작 |
| 2차 | langmapper.nvim | `korean.lua` | 플러그인 키맵(`<leader>ff` 등)의 한글 등가 자동 등록 |
| 3차 | im-select.nvim | `editor.lua` | Insert↔Normal 전환 시 IM 자동 전환 |

**진단**:
```vim
" langmapper 로드 확인
:Lazy check langmapper.nvim

" FocusGained autocmd 확인
:autocmd FocusGained

" macism 동작 확인 (터미널에서)
macism    " 현재 입력소스 ID 출력
```

**langmap을 사용하지 않는 이유**: Neovim issue #27776 (멀티바이트 불안정), f/t 인자 충돌, IME 조합(자음+모음→음절) 문제.

**which-key 팝업에서 한글 미인식 시**: langmapper의 which-key v3 래퍼 추가 필요 (후속 작업).

**NixOS/SSH**: `cond = vim.fn.executable("macism") == 1`로 자동 비활성화. 성능 영향 없음.

## 플러그인 업데이트

```vim
:Lazy update           " 모든 플러그인 최신 버전으로 업데이트
:Lazy restore          " lazy-lock.json 기준으로 복원
```

업데이트 후 `lazy-lock.json` 변경사항을 커밋하여 호스트 간 동기화.

## Nix 빌드 실패 (extraPackages)

```bash
# 패키지명 확인
nix search nixpkgs#vtsls
nix search nixpkgs#tailwindcss-language-server

# 빌드 테스트
nix build nixpkgs#vtsls
```

## ESLint 진단 중복

**원인**: eslint extra + nvim-lint에서 eslint_d를 별도 설정.
**해결**: LazyVim eslint extra만 사용. `eslint_d` 별도 설정 제거.

## macOS에서 nrs 빌드가 수십 분 멈춤 (LLVM 소스 빌드)

```
[1/13/58 built, 203 copied ...] building
# ps aux로 확인하면 clang++이 llvm-project를 컴파일 중
```

**원인**: `extraPackages`에 `gcc`를 무조건 추가하면, macOS에서 GCC의 의존성인 **LLVM 전체를 소스에서 빌드**한다. nixpkgs 바이너리 캐시에 macOS용 GCC가 없기 때문.

**해결**: `gcc`를 Linux 전용으로 변경. macOS는 clang이 이미 있어 tree-sitter 파서 컴파일이 가능하다.

```nix
extraPackages = with pkgs; [ ... ]
++ lib.optionals pkgs.stdenv.isLinux [
  gcc  # NixOS 전용
];
```

**예방**: extraPackages에 C/C++ 컴파일러나 대형 빌드 도구를 추가할 때는 반드시 플랫폼 조건을 확인할 것. `pkgs.stdenv.isLinux` / `pkgs.stdenv.isDarwin`으로 분기.

## marksman이 Swift 소스 빌드를 트리거 (빌드 실패)

```
error: Cannot build swift-5.10.1.drv
  → swift-wrapper-5.10.1 → dotnet-vmr-9.0.12 → dotnet-runtime → marksman
```

**원인**: `marksman`(Markdown LSP)은 .NET 앱. macOS에서 dotnet-runtime이 Swift를 빌드 의존성으로 요구하는데, nixpkgs 바이너리 캐시에 없어 소스 빌드 → clang 호환성 문제로 실패.

**해결**: `marksman` → `markdown-oxide`(Rust)로 교체. dotnet/Swift 의존성 없이 동일 기능 제공.

```nix
# default.nix
markdown-oxide  # marksman 대신 사용

# lsp.lua
markdown_oxide = {},
marksman = { enabled = false },
```

**교훈**: extraPackages 추가 시 `nix path-info -r nixpkgs#패키지명 | grep -ci swift` 등으로 무거운 의존성 체인이 없는지 사전 확인할 것.

## indent-blankline setup 함수 호출 실패

```
Error: You are trying to call the setup function of indent-blankline...
Take a look at the GitHub wiki for instructions on how to migrate.
```

**원인**: indent-blankline v3에서 모듈 이름이 `indent_blankline` → `ibl`로 변경됨. lazy.nvim이 플러그인명에서 모듈명을 추론하면 `indent-blankline`을 호출 → v2 호환 에러 발생.

**해결**: ui.lua의 플러그인 spec에 `main = "ibl"` 명시.

```lua
{
  "lukas-reineke/indent-blankline.nvim",
  main = "ibl",  -- v3 필수: 모듈명 명시
  opts = { ... },
}
```

**참고**: LazyVim 코어가 `main = "ibl"`을 설정하더라도, 커스텀 spec에서 명시적으로 지정하는 것이 안전함.

## tree-sitter CLI 누락 (파서 컴파일 불가)

```
Unmet requirements for nvim-treesitter main:
- ✅ C compiler
- ✅ curl
- ✅ tar
- ❌ tree-sitter (CLI)
```

**원인**: nvim-treesitter main 브랜치가 `tree-sitter` CLI를 필수 의존성으로 요구. `extraPackages`에 미포함 시 파서 설치 시 무한 행이 발생하거나 컴파일 실패.

**해결**: `default.nix`의 `extraPackages`에 `tree-sitter` 추가.

```nix
extraPackages = with pkgs; [
  tree-sitter  # nvim-treesitter 파서 컴파일 CLI
  # ...
];
```

**참고**: nixpkgs의 tree-sitter 버전이 nvim-treesitter 요구 버전(>= 0.26.1)보다 낮을 수 있음. `:checkhealth nvim-treesitter`로 버전 호환성 확인 필요.

## mini.surround 조직 이름 변경 경고

```
Plugin echasnovski/mini.surround was renamed to nvim-mini/mini.surround
Please update your config for LazyVim
```

**원인**: mini.nvim 0.17.0 (2025-12)에서 `echasnovski` 개인 계정 → `nvim-mini` 조직으로 이전. lazy.nvim은 `owner/repo` 문자열로 매칭하므로 옛 이름이면 경고 발생.

**해결**: `disabled.lua`에서 조직명 변경.

```lua
-- 올바른 방법
{ "nvim-mini/mini.surround", enabled = false }

-- 잘못된 방법 (경고 발생)
{ "echasnovski/mini.surround", enabled = false }
```

**교훈**: LazyVim 업데이트 후 플러그인 조직 이전 경고가 나타나면 `disabled.lua`의 `owner/repo`를 확인할 것.
