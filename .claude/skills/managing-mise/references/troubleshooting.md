# 트러블슈팅

mise 런타임 버전 관리자 관련 문제와 해결 방법을 정리합니다.

## 목차

- [SSH 비대화형 세션에서 pnpm not found](#ssh-비대화형-세션에서-pnpm-not-found)
- [mise가 .nvmrc 파일을 자동 인식하지 않음](#mise가-nvmrc-파일을-자동-인식하지-않음)
- [NixOS에서 node 빌드 실패](#nixos에서-node-빌드-실패)

---

## SSH 비대화형 세션에서 pnpm not found

> 발생 시점: 2026-01-18 (MiniPC에서 Node.js 프로젝트 작업)

증상: Mac에서 SSH로 MiniPC 접속 후 pnpm 명령 실행 시 찾을 수 없음.

```bash
$ ssh minipc 'cd /home/greenhead/Workspace/my-project && pnpm install'
pnpm not found
```

직접 터미널 접속(대화형 세션)에서는 정상 작동하지만, SSH 명령어(비대화형 세션)에서만 실패.

원인: SSH 비대화형 세션에서는 `.zshrc`가 로드되지 않아 mise가 활성화되지 않음.

| 세션 타입 | 로드되는 파일 | mise 활성화 |
|----------|--------------|------------|
| 대화형 (ssh 후 쉘) | `.zshenv` + `.zshrc` | O (`.zshrc`에서) |
| 비대화형 (ssh 명령어) | `.zshenv`만 | X |

기존 설정에서는 mise 활성화가 `.zshrc`에만 있었음:

```nix
# modules/shared/programs/shell/default.nix (기존)
programs.zsh.initContent = lib.mkBefore ''
  if command -v mise >/dev/null 2>&1; then
    eval "$(mise activate zsh)"
  fi
'';
```

해결: `.zshenv`에 mise shims 활성화 추가, `.zshrc`에 대화형 훅 + Claude Code snapshot 보강용 shims prepend 유지. shims 경로 표현은 `libraries/constants.nix`의 `mise.shimsDirExpr`에서 SoT로 관리한다.

```nix
# modules/shared/programs/shell/default.nix
let
  # constants.mise.shimsDirExpr 우선순위: MISE_DATA_DIR → XDG_DATA_HOME/mise → $HOME/.local/share/mise
  miseShimsDecl = ''_mise_shims="${constants.mise.shimsDirExpr}"'';
in
programs.zsh = {
  # .zshenv: snapshot 미경유 비대화형 세션을 위한 mise shims PATH 추가
  envExtra = ''
    ${miseShimsDecl}
    if command -v mise >/dev/null 2>&1 \
       && [[ ":$PATH:" != *":$_mise_shims:"* ]]; then
      eval "$(mise activate zsh --shims)"
    fi
    unset _mise_shims
  '';

  # .zshrc: 대화형 훅 + Claude Code snapshot 경유 비대화형 보강용 shims prepend
  initContent = lib.mkMerge [
    (lib.mkBefore ''
      if command -v mise >/dev/null 2>&1; then
        eval "$(mise activate zsh)"
        ${miseShimsDecl}
        [[ ":$PATH:" != *":$_mise_shims:"* ]] && export PATH="$_mise_shims:$PATH"
        unset _mise_shims
      fi
    '')
  ];
};
```

차이점:

| 활성화 방식 | 용도 | 기능 |
|-----------|------|------|
| `mise activate zsh --shims` | 비대화형 | PATH에 shim 디렉토리만 추가 |
| `mise activate zsh` + shims prepend | 대화형 + Claude Code snapshot 보강 | 전체 훅 (cd 시 자동 버전 전환 등) + 직후 shims를 PATH 맨 앞에 박아 snapshot 캡처 시점에 포함되도록 보장 |

확인:

```bash
$ ssh minipc 'cd /home/greenhead/Workspace/my-project && pnpm --version'
9.15.4
```

참고: darwin(Mac)과 NixOS 모두 동일한 설정을 사용하므로, 이 변경은 양쪽에 영향을 줍니다. 중복 활성화 방지는 shims 경로의 PATH 실재 여부 가드로 한다 — 과거 `MISE_SHELL` 기반 가드는 부모 대화형 셸의 `MISE_SHELL`이 자식 비대화형 셸로 상속되어 shims 활성화를 조기 스킵하는 회귀를 만들어 폐기됐다.

추가 회귀 경로 — Claude Code Bash tool 비대화형 (#857): Claude Code는 세션 시작 시 interactive 셸 PATH를 `~/.claude/shell-snapshots/snapshot-zsh-*.sh`에 박제하고 Bash tool 호출마다 그 snapshot.sh를 source해 PATH를 복원한다. `mise activate zsh`(hook 모드)는 호출 끝에 `_mise_hook`을 즉시 발동시켜 install-bins를 PATH에 prepend하지만, hook 모드 정책상 shims는 prepend 안 한다 — snapshot에 install-bins는 들어가도 shim 의존 mise 도구(pnpm 등)는 비대화형에서 미노출된다. `.zshrc`에서 `mise activate zsh` 직후 shims를 명시적으로 PATH에 prepend하면 snapshot에 shims가 포함되어 비대화형 호출이 동작한다. (과거 이 회귀의 대표 사례였던 codex는 #890에서 nix overlay로 이관돼 mise shim 무관.) 회귀 메커니즘과 fallback 후보의 SoT는 `managing-mise/SKILL.md`의 "셸 활성화 구조" 섹션이다.

---

## mise가 .nvmrc 파일을 자동 인식하지 않음

> 발생 시점: 2026-01-18 (MiniPC에서 Node.js 프로젝트 작업)

증상: 프로젝트에 `.nvmrc` 파일이 있는데도 mise가 해당 버전을 사용하지 않음.

```bash
$ cat .nvmrc
20.18

$ mise current
node 24.13.0    # .nvmrc의 20.18이 아닌 전역 설정 사용
pnpm 10.28.0
```

원인: mise 2025.10.0부터 idiomatic version file (`.nvmrc`, `.node-version` 등)이 기본적으로 비활성화됨. 이는 버그가 아닌 의도된 동작.

배경:
- mise 초기에는 모든 언어에 플러그인이 필요했기 때문에 기본 활성화가 합리적이었음
- 이제 대부분의 도구가 코어에 포함되면서, `go.mod`나 `Gemfile`이 있는 것만으로 해당 도구가 자동 설치되는 것이 부자연스럽다고 판단
- "legacy version file" 대신 "idiomatic version file"로 용어 변경 (asdf/mise에 종속되지 않는 파일이므로)

참고 링크:
- [GitHub Issue #3212: rename "legacy files" -> "idiomatic files"](https://github.com/jdx/mise/issues/3212)
- [Discussion #4345: idiomatic versions default disabled](https://github.com/jdx/mise/discussions/4345)
- [mise 공식 설정 문서](https://mise.jdx.dev/configuration.html)

해결: `idiomatic_version_file_enable_tools` 설정 추가.

현재는 전역 config가 nix 선언(`modules/shared/programs/mise/config.toml`)이고 이 설정이 이미 포함돼 있어 별도 조치가 불필요하다. 새 도구를 idiomatic file 인식 대상에 추가하려면 SoT 파일을 수정 후 `nrs`한다 (`mise settings add`는 read-only config라 실패한다):

```toml
# modules/shared/programs/mise/config.toml
[settings]
idiomatic_version_file_enable_tools = ["node"]

[tools]
node = "lts"      # 전역 기본값
pnpm = "latest"
```

프로젝트별 버전 설치:

```bash
# 프로젝트의 .nvmrc에 맞는 버전 설치
$ MISE_NODE_COMPILE=0 mise install node@20.18
```

확인:

```bash
$ cd /path/to/project
$ mise current
node 20.18.3    # .nvmrc 버전 사용
pnpm 10.28.0
```

대안: mise.local.toml 사용 (프로젝트에 mise 설정 커밋하지 않을 때):

프로젝트에서 mise를 공식적으로 사용하지 않지만 개인적으로 사용하고 싶을 때:

```bash
# 프로젝트 디렉토리에 로컬 설정 생성
$ cat > mise.local.toml << 'EOF'
[tools]
node = "20.18"
pnpm = "latest"
EOF

# trust 실행 (최초 1회)
$ mise trust
```

> 참고: `mise.local.toml`과 `.mise.local.toml` 둘 다 global gitignore에 추가되어 있습니다 (`modules/shared/programs/git/default.nix`). mise는 "mise"로 시작하는 파일에 dotfile 버전(`.mise.*`)도 지원합니다.

참고: `idiomatic_version_file_enable_tools` 설정이 있으면 `mise.local.toml` 없이도 `.nvmrc`가 인식됩니다. 둘 중 편한 방법을 선택하면 됩니다.

---

## NixOS에서 node 빌드 실패

증상: mise로 node 설치 시 빌드 실패.

```bash
$ mise install node@lts
./configure: line 8: exec: python: not found
```

원인: mise는 기본적으로 node를 소스에서 빌드하려 하지만, NixOS에서는 python이 없어 실패함.

해결: 바이너리 버전 사용.

```bash
# 환경변수로 컴파일 비활성화
$ MISE_NODE_COMPILE=0 mise install node@lts
```

현재는 `modules/shared/programs/shell/nixos.nix`가 `MISE_NODE_COMPILE=0`·`MISE_ALL_COMPILE=0`을 영구 설정하므로 평상시엔 재발하지 않는다.

확인:

```bash
$ node --version
v22.12.0
```
