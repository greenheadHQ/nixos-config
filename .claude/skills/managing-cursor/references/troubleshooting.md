# 트러블슈팅

## Cursor 관련

### Spotlight에서 Cursor가 2개로 표시됨

**원인**: `programs.vscode.package = pkgs.code-cursor` 사용 시 Nix store에도 Cursor가 설치됨

**해결**: 현재 설정은 이 문제를 해결한 구조입니다:
- Cursor 앱: Homebrew Cask로 설치 (`modules/darwin/programs/homebrew.nix`에서 선언적 관리)
- 확장 관리: `home.file`로 직접 관리 (`cursor/default.nix`)

```bash
# 확인: Nix store에 Cursor 앱이 없어야 함
nix-store -qR /nix/var/nix/profiles/system | grep -i "cursor.*Applications"
# (출력 없음이 정상)
```

### Cursor Extensions GUI에서 확장이 0개로 표시됨

**원인**: `extensions.json` 형식이 Cursor가 기대하는 형식과 다름

**해결**: `extensions.json`에 `location`과 `metadata` 필드가 필요:

```json
{
  "identifier": {"id": "..."},
  "version": "...",
  "location": {"$mid": 1, "path": "/Users/.../.cursor/extensions/...", "scheme": "file"},
  "relativeLocation": "...",
  "metadata": {"installedTimestamp": 0, "targetPlatform": "undefined"}
}
```

현재 `cursor/default.nix`는 이 형식으로 생성하도록 구성되어 있습니다.

```bash
# 확인: extensions.json 형식
cat ~/.cursor/extensions/extensions.json | jq '.[0]'
```

### "Extensions have been modified on disk" 경고

**원인**: `darwin-rebuild switch` 실행 시 `~/.cursor/extensions` 심볼릭 링크가 새 Nix store 경로로 변경됨

**해결**: 정상적인 동작입니다
- "Reload Window" 클릭
- 또는 Cursor 재시작

이 경고는 Nix 기반 불변(immutable) 확장 관리의 특성입니다.

### Cursor에서 확장 설치/제거가 안 됨

**원인**: `~/.cursor/extensions`가 Nix store로 심볼릭 링크되어 읽기 전용

**해결**: 의도된 동작입니다. 확장 관리는 Nix로만 가능:

```bash
# 1. cursor/default.nix에서 cursorExtensions 수정
# 2. 적용
git add modules/darwin/programs/cursor/default.nix
darwin-rebuild switch --flake .
# 3. Cursor 재시작
```

> **참고**: Cursor 확장 관리에 대한 자세한 내용은 [extensions.md](extensions.md)를 참고하세요.
