# VSCode 설정

VSCode 에디터 관련 설정입니다.

## 목차

- [에디터 탭 라벨 커스터마이징](#에디터-탭-라벨-커스터마이징)
- [Nix LSP (nixd)](#nix-lsp-nixd)
- [기본 앱 설정 (duti)](#기본-앱-설정-duti)

---

`modules/darwin/programs/vscode/`에서 관리됩니다.

## 에디터 탭 라벨 커스터마이징

`settings.json`의 `workbench.editor.customLabels.patterns`를 사용하여 Next.js 프로젝트의 탭 가독성을 개선합니다.

**문제 상황**: Next.js App Router 사용 시 `page.tsx`, `layout.tsx` 등 동일한 파일명이 여러 탭에 열리면 구분이 어려움.

**해결**: 폴더명을 함께 표시하여 어느 라우트의 파일인지 즉시 파악 가능.

| 파일 경로                | Before         | After                |
| ------------------------ | -------------- | -------------------- |
| `app/dashboard/page.tsx` | `page.tsx`     | `dashboard/page.tsx` |
| `app/auth/loading.tsx`   | `loading.tsx`  | `auth/loading.tsx`   |
| `pages/api/index.ts`     | `index.ts`     | `api/index.ts`       |
| `features/cart/hooks.ts` | `hooks.ts`     | `cart/hooks.ts`      |
| `lib/api/constants.ts`   | `constants.ts` | `api/constants.ts`   |

**지원 패턴:**

| 패턴         | 대상 파일                                                                | 표시 형식          |
| ------------ | ------------------------------------------------------------------------ | ------------------ |
| App Router   | `page`, `layout`, `loading`, `error`, `not-found`, `template`, `default` | `dirname/filename` |
| Pages Router | `index`, `_app`, `_document`, `_error`                                   | `dirname/filename` |
| 공통 index   | `index.ts(x)`                                                            | `dirname/index`    |
| 유틸리티     | `hook(s)`, `constant(s)`, `util(s)`, `state(s)`, `type(s)`, `style(s)`   | `dirname/filename` |

## Nix LSP (nixd)

VSCode에서 `.nix` 파일 편집 시 nixd LSP를 사용합니다.

**설정 위치**: `modules/darwin/programs/vscode/files/settings.json`

```json
"nix.enableLanguageServer": true,
"nix.serverPath": "nixd",
"nix.serverSettings": {
  "nixd": {
    "formatting": { "command": ["nixfmt"] }
  }
}
```

**패키지 위치**: `modules/darwin/programs/vscode/default.nix`의 `home.packages`

- `pkgs.nixd` — Nix LSP 서버
- `pkgs.nixfmt` — Nix 포매터 (nixd formatting 의존성)

nixd와 nixfmt를 VSCode 모듈에 co-locate하여 macOS에서만 설치합니다 (NixOS에서는 Neovim이 nil을 사용).

**확인 방법:**

```bash
# nixd 동작 확인
nixd --version

# VSCode에서 .nix 파일 열기 → 상태바에 nixd 표시
# 옵션 자동완성, go-to-definition 동작 확인
```

## 기본 앱 설정 (duti)

텍스트/코드 파일을 더블클릭 시 Xcode 대신 VSCode로 열리도록 `duti`를 사용하여 파일 연결을 설정합니다.

**설정 대상 확장자:**

```
txt, text, md, mdx, js, jsx, ts, tsx, mjs, cjs,
json, yaml, yml, toml, css, scss, sass, less, nix,
sh, bash, zsh, py, rb, go, rs, lua, sql, graphql, gql,
xml, svg, conf, ini, cfg, env, gitignore, editorconfig, prettierrc, eslintrc
```

**설정 대상 UTI:**

| UTI                  | 설명             |
| -------------------- | ---------------- |
| `public.plain-text`  | 일반 텍스트 파일 |
| `public.source-code` | 소스 코드 파일   |

> `public.data`는 범위가 너무 넓어 제거함.

**동작 방식:**

- Home Manager의 `home.activation`을 사용하여 `darwin-rebuild switch` 시 자동 적용
- `duti -s <bundle-id> .<ext> all` 명령으로 각 확장자 설정
- Xcode 업데이트 시에도 `darwin-rebuild switch` 재실행으로 복구 가능

**확인 방법:**

```bash
# 특정 확장자의 기본 앱 확인
duti -x txt
# 예상 출력: Visual Studio Code.app

# Bundle ID 확인
mdls -name kMDItemCFBundleIdentifier ~/Applications/Home\ Manager\ Apps/Visual\ Studio\ Code.app
```

> **참고**: `.html`, `.htm` 확장자는 Safari가 시스템 수준에서 보호하므로 설정 불가.
