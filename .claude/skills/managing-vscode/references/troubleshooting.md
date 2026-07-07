# 트러블슈팅

## VSCode 관련

### 확장 로드 오류 / 확장이 보이지 않음

원인: `nrs` 실행 후 확장 디렉토리가 변경되었지만 VSCode가 이전 경로를 캐시

해결: VSCode 재시작 (Cmd+Shift+P → "Reload Window" 또는 앱 재시작)

### GUI에서 확장 설치/제거가 안 됨

원인: `mutableExtensionsDir = false` 설정으로 확장 디렉토리가 읽기 전용

해결: 의도된 동작입니다. 확장 관리는 Nix로만 가능:

```bash
# 1. vscode/default.nix에서 profiles.default.extensions 수정
# 2. 적용
nrs
# 3. VSCode 재시작
```

> 참고: VSCode 확장 관리에 대한 자세한 내용은 [extensions.md](extensions.md)를 참고하세요.

### settings.json / keybindings.json 변경이 반영 안 됨

원인: mkOutOfStoreSymlink으로 관리되므로 파일 경로가 nixos-config 레포를 가리킴

확인:

```bash
# 심링크 타깃 확인
ls -la ~/Library/Application\ Support/Code/User/settings.json
# → nixos-config/modules/darwin/programs/vscode/files/settings.json

ls -la ~/Library/Application\ Support/Code/User/keybindings.json
# → nixos-config/modules/darwin/programs/vscode/files/keybindings.json
```

해결: VSCode UI에서 설정 변경 시 nixos-config의 파일이 직접 수정됨 (양방향). 변경이 반영 안 되면 VSCode 재시작.

### nixd LSP가 동작하지 않음

확인:

```bash
# nixd가 PATH에 있는지 확인
which nixd

# nixd 버전 확인
nixd --version
```

해결:

1. `modules/darwin/programs/vscode/default.nix`에 `pkgs.nixd`가 `home.packages`에 있는지 확인
2. `nrs` 재실행
3. VSCode 재시작
4. 상태바에서 nix-ide 언어 서버 상태 확인

### Bundle ID 불일치

`duti` 파일 연결이 동작하지 않을 때:

```bash
# 실제 Bundle ID 확인
mdls -name kMDItemCFBundleIdentifier ~/Applications/Home\ Manager\ Apps/Visual\ Studio\ Code.app

# 예상값: com.microsoft.VSCode
# 불일치 시 modules/darwin/programs/vscode/default.nix의 vscodeBundleId 수정
```

### vscode:// 링크 클릭이 VSCode가 아닌 Finder로 열림

증상: statusline 등에서 `vscode://` 링크를 클릭했는데 VSCode가 열리지 않고 Finder나 다른 fallback 핸들러가 실행됨.

원인: macOS LaunchServices DB의 VSCode URL scheme handler 등록이 stale 상태. 파일 확장자 기본 앱 매핑(`duti`)과 별개로, `.app` bundle의 `CFBundleURLTypes` 재등록이 필요함.

해결: `modules/darwin/programs/vscode/default.nix`의 `home.activation.refreshVSCodeLaunchServices`가 `nrs` 시 Home Manager Apps trampoline을 `lsregister -f`로 재등록합니다.

진단:

```bash
rg -n "refreshVSCodeLaunchServices|lsregister" modules/darwin/programs/vscode/default.nix
```

수동 확인 후에도 계속 Finder로 빠지면 `nrs`를 재실행하고 VSCode 앱이 `~/Applications/Home Manager Apps/Visual Studio Code.app`에 존재하는지 확인합니다.

### darwin-rebuild 시 setupLaunchAgents에서 멈춤

`nrs` 실행 시 `Activating setVSCodeAsDefaultEditor` 후 `setupLaunchAgents`에서 멈추는 경우:

```
Activating setVSCodeAsDefaultEditor
Setting VSCode as default editor for code files...
VSCode default settings applied.
Activating setupLaunchAgents
← 여기서 멈춤
```

이 문제는 VSCode 모듈이 아닌 launchd 에이전트 관련 문제입니다. managing-macos 스킬의 트러블슈팅을 참고하세요.
