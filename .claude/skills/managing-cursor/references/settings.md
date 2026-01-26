# Cursor 설정

Cursor AI 코드 에디터 관련 설정입니다.

## 목차

- [Tab 자동완성 우선순위](#tab-자동완성-우선순위)
- [에디터 탭 라벨 커스터마이징](#에디터-탭-라벨-커스터마이징)
- [기본 앱 설정 (duti)](#기본-앱-설정-duti)

---

`modules/darwin/programs/cursor/`에서 관리됩니다.

## Tab 자동완성 우선순위

> **참고**: Cursor 2.3.35 기준

Cursor의 Tab 자동완성(AI 기반)과 VS Code IntelliSense(언어 서버 기반)가 동시에 표시될 때, **Tab 키는 Cursor 자동완성을 우선 처리**합니다. IntelliSense 제안은 무시됩니다.

- **Tab**: Cursor AI 자동완성 수락
- **방향키(위/아래)**: IntelliSense 제안 탐색
- **Enter**: IntelliSense 제안 수락

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

## 기본 앱 설정 (duti)

텍스트/코드 파일을 더블클릭 시 Xcode 대신 Cursor로 열리도록 `duti`를 사용하여 파일 연결을 설정합니다.

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
| `public.data`        | 범용 데이터 파일 |

**동작 방식:**

- Home Manager의 `home.activation`을 사용하여 `darwin-rebuild switch` 시 자동 적용
- `duti -s <bundle-id> .<ext> all` 명령으로 각 확장자 설정
- Xcode 업데이트 시에도 `darwin-rebuild switch` 재실행으로 복구 가능

**확인 방법:**

```bash
# 특정 확장자의 기본 앱 확인
duti -x txt
# 예상 출력: Cursor.app

# Bundle ID 확인 (Cursor 업데이트 시)
mdls -name kMDItemCFBundleIdentifier /Applications/Cursor.app
```

> **참고**: `.html`, `.htm` 확장자는 Safari가 시스템 수준에서 보호하므로 설정 불가.
