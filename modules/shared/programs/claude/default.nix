# Claude Code 설정 (공통)
# Homebrew로 앱 설치, Nix로 설정 관리
{
  config,
  pkgs,
  lib,
  constants,
  nixosConfigPath,
  ...
}:

let
  claudeDir = ./files;
  # mkOutOfStoreSymlink용 절대 경로 (양방향 수정 가능)
  claudeFilesPath = "${nixosConfigPath}/modules/shared/programs/claude/files";

  # viewing-immich-photo 스킬 (constants 참조로 경로 중앙 관리)
  viewingImmichPhotoSkill = pkgs.writeTextFile {
    name = "SKILL.md";
    text = ''
      ---
      name: viewing-immich-photo
      description: |
        Immich photo viewer: resolve photo paths, display images.
        Triggers: "view immich photo", "이미치 사진 확인", "immich 파일 보여줘",
        "immich 사진 보여줘", paths containing "${constants.paths.immichUploadCache}"
        or "${constants.paths.dockerData}/immich".
      ---

      # Immich 사진 확인

      macOS 또는 NixOS 환경에서 immich 사진 경로를 받아 이미지를 확인하는 방법입니다.

      ## 경로 검증 (보안)

      요청된 경로가 immich 디렉토리 내부인지 먼저 확인:
      - 허용 경로: `${constants.paths.immichUploadCache}/` 또는 `${constants.paths.dockerData}/immich/`
      - `..` 포함 경로는 거부 (path traversal 방지)

      ## 플랫폼 감지

      환경 정보에서 플랫폼 확인:
      - `<env>` 블록의 `Platform: darwin` → macOS
      - `<env>` 블록의 `Platform: linux` → NixOS

      ## macOS에서 실행 시

      MiniPC에 저장된 파일이므로 SSH로 가져온 후 Read 도구로 확인합니다.

      ### 단계

      1. 경로가 `${constants.paths.immichUploadCache}`로 시작하는지 확인
      2. SSH로 파일을 `/tmp`에 복사 (확장자 유지)
      3. Read 도구로 이미지 확인
      4. 삭제 불필요 (`/tmp`는 시스템 자동 정리)

      ### 명령어

      ```bash
      # 확장자 추출하여 유지
      EXT="''${FILE_PATH##*.}"
      ssh minipc "cat <원본경로>" > "/tmp/immich_photo_$(date +%s).$EXT"
      ```

      **주의**: `minipc`는 SSH config에 정의된 호스트 alias.

      ## NixOS에서 실행 시

      로컬 파일이므로 경로를 직접 Read 도구에 전달합니다.

      ## 경로 패턴

      | 유형 | 경로 패턴 |
      |------|----------|
      | 업로드 캐시 | `${constants.paths.immichUploadCache}/UUID/xx/xx/file.ext` |
      | 라이브러리 | `${constants.paths.dockerData}/immich/library/UUID/YYYY/MM/file.ext` |

      ## 경로 변환 (Immich API → 호스트)

      | Immich API 경로 | 호스트 경로 |
      |-----------------|-------------|
      | `/usr/src/app/upload/upload/` | `${constants.paths.immichUploadCache}/` |

      ## 지원 파일 형식

      Read 도구는 이미지를 시각적으로 표시:
      - 이미지: `.jpg`, `.jpeg`, `.png`, `.webp`, `.gif`
      - 동영상: 확인 불가 (메타데이터만 표시)

      **참고**: Scriptable 업로드는 항상 `.jpg`로 저장됨

      ## 오류 처리

      | 상황 | 대응 |
      |------|------|
      | SSH 연결 실패 | `tailscale status` 확인, `ssh minipc "echo ok"` 테스트 |
      | 파일 없음 | 경로 오타 확인, Immich API 경로→호스트 경로 변환 확인 |
      | 권한 없음 | 파일 소유자/권한 확인 (`ls -la <path>`) |
    '';
  };
in
{
  # Binary Claude Code 설치 (Node.js 버전 의존성 없음)
  home.activation.installClaudeCode = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    if [ ! -f "$HOME/.local/bin/claude" ]; then
      echo "Installing Claude Code binary..."
      ${pkgs.curl}/bin/curl -fsSL https://claude.ai/install.sh | ${pkgs.bash}/bin/bash
    else
      echo "Claude Code already installed at $HOME/.local/bin/claude"
    fi
  '';

  # 프로젝트 스킬 생성 (viewing-immich-photo)
  # Nix로 생성하여 constants.nix 경로 참조 → 경로 변경 시 자동 반영
  home.activation.createImmichPhotoSkill = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    SKILL_DIR="${nixosConfigPath}/.claude/skills/viewing-immich-photo"
    $DRY_RUN_CMD mkdir -p "$SKILL_DIR"
    $DRY_RUN_CMD ln -sf "${viewingImmichPhotoSkill}" "$SKILL_DIR/SKILL.md"
  '';

  # ~/.claude/ 디렉토리 관리 (선택적 파일만)
  home.file = {
    # 메인 설정 파일 - 양방향 수정 가능 (nixos-config 직접 참조)
    # Claude Code에서 플러그인 설치/설정 변경 시 nixos-config에 바로 반영됨
    ".claude/settings.json".source =
      config.lib.file.mkOutOfStoreSymlink "${claudeFilesPath}/settings.json";

    # MCP 설정 - 양방향 수정 가능
    ".claude/mcp.json".source = config.lib.file.mkOutOfStoreSymlink "${claudeFilesPath}/mcp.json";

    # User-scope 지침 - 양방향 수정 가능 (Astral 플러그인 등 전역 설정)
    ".claude/CLAUDE.md".source = config.lib.file.mkOutOfStoreSymlink "${claudeFilesPath}/CLAUDE.md";

    # Hooks - mkOutOfStoreSymlink로 nrs 없이 즉시 반영 (소스 파일에 chmod +x 필수)
    ".claude/hooks/stop-notification.sh".source =
      config.lib.file.mkOutOfStoreSymlink "${claudeFilesPath}/hooks/stop-notification.sh";
    ".claude/hooks/ask-notification.sh".source =
      config.lib.file.mkOutOfStoreSymlink "${claudeFilesPath}/hooks/ask-notification.sh";
    ".claude/hooks/plan-notification.sh".source =
      config.lib.file.mkOutOfStoreSymlink "${claudeFilesPath}/hooks/plan-notification.sh";

    # agent-browser 스킬 (user-scope)
    ".claude/skills/agent-browser".source =
      config.lib.file.mkOutOfStoreSymlink "${claudeFilesPath}/skills/agent-browser";

    # syncing-codex-harness 스킬 (user-scope)
    ".claude/skills/syncing-codex-harness".source =
      config.lib.file.mkOutOfStoreSymlink "${claudeFilesPath}/skills/syncing-codex-harness";

    # karpathy-guidelines 스킬 (user-scope)
    # 출처: https://github.com/forrestchang/andrej-karpathy-skills (MIT)
    # Andrej Karpathy의 LLM 코딩 행동 가이드라인 — 매 세션 CLAUDE.md에서 핵심 원칙 로드
    ".claude/skills/karpathy-guidelines".source =
      config.lib.file.mkOutOfStoreSymlink "${claudeFilesPath}/skills/karpathy-guidelines";

    # managing-github-issues 스킬 (user-scope)
    ".claude/skills/managing-github-issues".source =
      config.lib.file.mkOutOfStoreSymlink "${claudeFilesPath}/skills/managing-github-issues";
  };
}
