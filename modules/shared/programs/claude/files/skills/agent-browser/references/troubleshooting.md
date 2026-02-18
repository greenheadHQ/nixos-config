# agent-browser 트러블슈팅 (NixOS/nix-darwin)

이 문서는 NixOS 및 nix-darwin 환경에서 발생하는 agent-browser 특화 문제를 다룹니다.

## `agent-browser: command not found`

**원인**: `$HOME/.npm-global/bin`이 PATH에 없음

**해결**:
```bash
# PATH 확인
echo $PATH | tr ':' '\n' | grep npm-global

# 새 셸 세션 시작 (home.sessionPath 반영)
exec zsh

# 직접 확인
ls -la $HOME/.npm-global/bin/agent-browser
```

설정 위치: `~/Workspace/nixos-config/modules/shared/programs/agent-browser/default.nix`의 `home.sessionPath`

## Chromium 실행 실패 (NixOS)

**증상**: `agent-browser open` 실행 시 shared library 에러

```
error while loading shared libraries: libnss3.so: cannot open shared object file
```

**원인**: Playwright의 Chromium은 동적 링크 바이너리로 FHS 라이브러리 경로를 기대하지만, NixOS는 FHS를 따르지 않음

**해결**: `~/Workspace/nixos-config/modules/nixos/configuration.nix`에서 `programs.nix-ld.libraries` 확인

```nix
programs.nix-ld.enable = true;
programs.nix-ld.libraries = with pkgs; [
  nss nspr atk cups dbus libdrm libgbm mesa
  pango cairo expat at-spi2-core alsa-lib glib gtk3
  gdk-pixbuf freetype fontconfig
  xorg.libX11 xorg.libXcomposite xorg.libXdamage
  xorg.libXext xorg.libXfixes xorg.libXrandr
  xorg.libXcursor xorg.libXi xorg.libXrender
  xorg.libxcb xorg.libxshmfence
  libxkbcommon
];
```

### 누락 라이브러리 매핑

에러 메시지의 `.so` 파일명으로 대응 패키지 확인:

| .so 파일 | Nix 패키지 |
|----------|-----------|
| `libnss3.so` | `nss` |
| `libnspr4.so` | `nspr` |
| `libatk-1.0.so` | `atk` |
| `libcups.so` | `cups` |
| `libdbus-1.so` | `dbus` |
| `libdrm.so` | `libdrm` |
| `libgbm.so` | `libgbm` |
| `libpango-1.0.so` | `pango` |
| `libcairo.so` | `cairo` |
| `libX11.so` | `xorg.libX11` |
| `libxkbcommon.so` | `libxkbcommon` |
| `libasound.so` | `alsa-lib` |
| `libgtk-3.so` | `gtk3` |
| `libatspi.so` | `at-spi2-core` |
| `libfreetype.so` | `freetype` |
| `libfontconfig.so` | `fontconfig` |
| `libgdk_pixbuf-2.0.so` | `gdk-pixbuf` |
| `libXshmfence.so` | `xorg.libxshmfence` |

## `node: command not found` (데몬 시작 실패)

**증상**: `agent-browser open` 실행 시 daemon 시작 실패

**원인**: agent-browser의 Rust CLI가 `Command::new("node")` (connection.rs)로 데몬을 시작하는데, `node`가 PATH에 없음

**해결**: mise가 Node.js를 관리하므로, mise가 활성화된 대화형 셸에서 실행

```bash
# mise 활성화 확인
which node
# 출력: ~/.local/share/mise/installs/node/xx.x.x/bin/node

# mise가 활성화되지 않았다면
eval "$(mise activate zsh)"
```

**참고**: 비대화형 SSH 환경에서는 mise shim이 PATH에 없을 수 있음. 대화형 셸(`ssh minipc` 후 직접 실행)에서 사용 권장.

## `agent-browser install --with-deps` 실패

**증상**: apt-get/dnf/yum을 찾을 수 없다는 에러

**원인**: NixOS는 FHS 패키지 매니저를 사용하지 않음. `agent-browser install --with-deps`는 apt-get 등을 호출 (install.rs)

**해결**: `--with-deps` 없이 실행하고, 시스템 라이브러리는 `nix-ld.libraries`로 관리

```bash
# Chromium만 설치 (시스템 deps는 nix-ld.libraries가 제공)
agent-browser install
# 또는
npx playwright install chromium
```

## Chromium 재설치

Chromium을 다시 설치해야 하는 경우:

```bash
# 기존 캐시 삭제
rm -rf ~/.cache/ms-playwright/

# 재설치
npx playwright install chromium
```

macOS의 경우 캐시 경로: `~/Library/Caches/ms-playwright/`

## 관련 설정 파일

| 파일 | 역할 |
|------|------|
| `~/Workspace/nixos-config/modules/shared/programs/agent-browser/default.nix` | 설치 + PATH |
| `~/Workspace/nixos-config/modules/nixos/configuration.nix` | nix-ld.libraries |
| `~/.npm-global/bin/agent-browser` | 설치된 바이너리 |
| `~/.cache/ms-playwright/` | Chromium 캐시 (Linux) |
| `~/Library/Caches/ms-playwright/` | Chromium 캐시 (macOS) |
