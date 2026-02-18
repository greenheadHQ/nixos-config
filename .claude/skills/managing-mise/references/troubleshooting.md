# 트러블슈팅

mise 런타임 버전 관리자 관련 문제와 해결 방법을 정리합니다.

## 목차

- [SSH 비대화형 세션에서 pnpm not found](#ssh-비대화형-세션에서-pnpm-not-found)
- [mise가 .nvmrc 파일을 자동 인식하지 않음](#mise가-nvmrc-파일을-자동-인식하지-않음)
- [NixOS에서 node 빌드 실패](#nixos에서-node-빌드-실패)

---

## SSH 비대화형 세션에서 pnpm not found

> **발생 시점**: 2026-01-18 (MiniPC에서 Node.js 프로젝트 작업)

**증상**: Mac에서 SSH로 MiniPC 접속 후 pnpm 명령 실행 시 찾을 수 없음.

```bash
$ ssh minipc 'cd /home/greenhead/Workspace/my-project && pnpm install'
pnpm not found
```

직접 터미널 접속(대화형 세션)에서는 정상 작동하지만, SSH 명령어(비대화형 세션)에서만 실패.

**원인**: SSH 비대화형 세션에서는 `.zshrc`가 로드되지 않아 mise가 활성화되지 않음.

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

**해결**: `.zshenv`에 mise shims 활성화 추가, `.zshrc`에 대화형 훅 유지.

```nix
# modules/shared/programs/shell/default.nix
programs.zsh = {
  # .zshenv: SSH 비대화형 세션을 위한 mise shims PATH 추가
  envExtra = ''
    if command -v mise >/dev/null 2>&1 && [[ -z "$MISE_SHELL" ]]; then
      eval "$(mise activate zsh --shims)"
    fi
  '';

  # .zshrc: 대화형 셸을 위한 전체 훅 활성화
  initContent = lib.mkMerge [
    (lib.mkBefore ''
      if command -v mise >/dev/null 2>&1; then
        eval "$(mise activate zsh)"
      fi
    '')
  ];
};
```

**차이점**:

| 활성화 방식 | 용도 | 기능 |
|-----------|------|------|
| `mise activate zsh --shims` | 비대화형 | PATH에 shim 디렉토리만 추가 |
| `mise activate zsh` | 대화형 | 전체 훅 (cd 시 자동 버전 전환 등) |

**확인**:

```bash
$ ssh minipc 'cd /home/greenhead/Workspace/my-project && pnpm --version'
9.15.4
```

**참고**: darwin(Mac)과 NixOS 모두 동일한 설정을 사용하므로, 이 변경은 양쪽에 영향을 줍니다. `MISE_SHELL` 환경변수 체크로 중복 활성화를 방지합니다.

---

## mise가 .nvmrc 파일을 자동 인식하지 않음

> **발생 시점**: 2026-01-18 (MiniPC에서 Node.js 프로젝트 작업)

**증상**: 프로젝트에 `.nvmrc` 파일이 있는데도 mise가 해당 버전을 사용하지 않음.

```bash
$ cat .nvmrc
20.18

$ mise current
node 24.13.0    # .nvmrc의 20.18이 아닌 전역 설정 사용
pnpm 10.28.0
```

**원인**: mise 2025.10.0부터 **idiomatic version file** (`.nvmrc`, `.node-version` 등)이 기본적으로 **비활성화**됨. 이는 버그가 아닌 **의도된 동작**.

**배경**:
- mise 초기에는 모든 언어에 플러그인이 필요했기 때문에 기본 활성화가 합리적이었음
- 이제 대부분의 도구가 코어에 포함되면서, `go.mod`나 `Gemfile`이 있는 것만으로 해당 도구가 자동 설치되는 것이 부자연스럽다고 판단
- "legacy version file" 대신 "idiomatic version file"로 용어 변경 (asdf/mise에 종속되지 않는 파일이므로)

**참고 링크**:
- [GitHub Issue #3212: rename "legacy files" -> "idiomatic files"](https://github.com/jdx/mise/issues/3212)
- [Discussion #4345: idiomatic versions default disabled](https://github.com/jdx/mise/discussions/4345)
- [mise 공식 설정 문서](https://mise.jdx.dev/configuration.html)

**해결**: `idiomatic_version_file_enable_tools` 설정 추가.

```bash
# CLI로 설정
$ mise settings add idiomatic_version_file_enable_tools node
```

또는 `~/.config/mise/config.toml`에 직접 추가:

```toml
[settings]
idiomatic_version_file_enable_tools = ['node']

[tools]
node = "lts"      # 전역 기본값
pnpm = "latest"
```

**프로젝트별 버전 설치**:

```bash
# 프로젝트의 .nvmrc에 맞는 버전 설치
$ MISE_NODE_COMPILE=0 mise install node@20.18
```

**확인**:

```bash
$ cd /path/to/project
$ mise current
node 20.18.3    # .nvmrc 버전 사용
pnpm 10.28.0
```

**대안: mise.local.toml 사용** (프로젝트에 mise 설정 커밋하지 않을 때):

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

> **참고**: `mise.local.toml`과 `.mise.local.toml` 둘 다 global gitignore에 추가되어 있습니다 (`modules/shared/programs/git/default.nix`). mise는 "mise"로 시작하는 파일에 dotfile 버전(`.mise.*`)도 지원합니다.

**참고**: `idiomatic_version_file_enable_tools` 설정이 있으면 `mise.local.toml` 없이도 `.nvmrc`가 인식됩니다. 둘 중 편한 방법을 선택하면 됩니다.

---

## NixOS에서 node 빌드 실패

**증상**: mise로 node 설치 시 빌드 실패.

```bash
$ mise use -g node@lts
./configure: line 8: exec: python: not found
```

**원인**: mise는 기본적으로 node를 소스에서 빌드하려 하지만, NixOS에서는 python이 없어 실패함.

**해결**: 바이너리 버전 사용.

```bash
# 환경변수로 컴파일 비활성화
$ MISE_NODE_COMPILE=0 mise use -g node@lts

# 또는 영구 설정 (~/.config/mise/config.toml)
[settings]
node_compile = false
```

**확인**:

```bash
$ node --version
v22.12.0
```
