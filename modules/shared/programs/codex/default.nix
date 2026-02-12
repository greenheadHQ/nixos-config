# Codex CLI 설정 (공통)
# Claude Code 스킬을 Codex에서도 사용할 수 있도록 심볼릭 링크 관리
# 이전 시도(5ef4e67)에서 trust 미설정으로 실패 → config.toml에 trust 필수
{
  config,
  pkgs,
  lib,
  nixosConfigPath,
  ...
}:

let
  codexFilesPath = "${nixosConfigPath}/modules/shared/programs/codex/files";
  # Claude 파일 경로 (공유 소스)
  claudeFilesPath = "${nixosConfigPath}/modules/shared/programs/claude/files";
in
{
  # ─── 글로벌 설정 (~/.codex/) ───

  home.file = {
    # Codex config.toml - 양방향 수정 가능 (codex mcp add 등 반영)
    # ⚠️ trust 설정 포함 — 이것이 .agents/skills/ 발견의 전제조건
    ".codex/config.toml".source = config.lib.file.mkOutOfStoreSymlink "${codexFilesPath}/config.toml";

    # 글로벌 AGENTS.md - Claude의 CLAUDE.md와 동일 소스 공유
    ".codex/AGENTS.md".source = config.lib.file.mkOutOfStoreSymlink "${claudeFilesPath}/CLAUDE.md";

    # 글로벌 스킬: agent-browser (Claude와 동일 소스 공유)
    ".codex/skills/agent-browser".source =
      config.lib.file.mkOutOfStoreSymlink "${claudeFilesPath}/skills/agent-browser";
  };

  # ─── 프로젝트 심볼릭 링크 (activation script) ───
  # 이전 시도(5ef4e67)의 sync-codex-from-claude.sh 로직을 Nix activation으로 이식
  # nrs 실행 시 자동으로 .agents/skills/ 동기화

  home.activation.createCodexProjectSymlinks =
    lib.hm.dag.entryAfter
      [
        "writeBoundary"
        "createImmichPhotoSkill" # viewing-immich-photo 스킬이 먼저 생성되어야 함
      ]
      ''
            PROJECT_DIR="${nixosConfigPath}"
            SOURCE_SKILLS="$PROJECT_DIR/.claude/skills"
            TARGET_SKILLS="$PROJECT_DIR/.agents/skills"

            # ── AGENTS.md → CLAUDE.md 심링크 ──
            if [ ! -L "$PROJECT_DIR/AGENTS.md" ] || [ "$(readlink "$PROJECT_DIR/AGENTS.md")" != "CLAUDE.md" ]; then
              $DRY_RUN_CMD ln -sfn "CLAUDE.md" "$PROJECT_DIR/AGENTS.md"
            fi

            # ── .agents/skills/ 디렉토리 생성 ──
            $DRY_RUN_CMD mkdir -p "$TARGET_SKILLS"

            # ── 스킬 투영 (심링크 + openai.yaml 생성) ──
            for source_skill_dir in "$SOURCE_SKILLS"/*/; do
              [ -d "$source_skill_dir" ] || continue
              [ -f "$source_skill_dir/SKILL.md" ] || continue

              skill_name="$(basename "$source_skill_dir")"
              target_skill_dir="$TARGET_SKILLS/$skill_name"

              $DRY_RUN_CMD mkdir -p "$target_skill_dir"

              # SKILL.md는 "실파일 복사"로 투영
              # 일부 Codex 환경에서 symlinked SKILL.md가 project-scope 스캔에서 누락될 수 있음
              skill_target="$target_skill_dir/SKILL.md"
              skill_source="$source_skill_dir/SKILL.md"
              if [ -L "$skill_target" ] || [ ! -f "$skill_target" ] || ! cmp -s "$skill_source" "$skill_target"; then
                $DRY_RUN_CMD rm -f "$skill_target"
                $DRY_RUN_CMD cp "$skill_source" "$skill_target"
              fi

              # references, scripts, assets 심링크 (존재 시)
              for child in references scripts assets; do
                if [ -e "$source_skill_dir/$child" ]; then
                  expected_child="../../../.claude/skills/$skill_name/$child"
                  if [ ! -L "$target_skill_dir/$child" ] || [ "$(readlink "$target_skill_dir/$child")" != "$expected_child" ]; then
                    $DRY_RUN_CMD ln -sf "$expected_child" "$target_skill_dir/$child"
                  fi
                fi
              done

              # agents/openai.yaml 자동 생성 (SKILL.md frontmatter 기반)
              $DRY_RUN_CMD mkdir -p "$target_skill_dir/agents"
              yaml_file="$target_skill_dir/agents/openai.yaml"

              # name 추출
              declared_name="$(${pkgs.gawk}/bin/awk '
                BEGIN { in_fm = 0 }
                /^---[[:space:]]*$/ { if (in_fm == 0) { in_fm = 1; next } else { exit } }
                in_fm == 1 && /^name:[[:space:]]*/ {
                  line = $0; sub(/^name:[[:space:]]*/, "", line);
                  gsub(/^[[:space:]]+|[[:space:]]+$/, "", line);
                  print line; exit
                }
              ' "$source_skill_dir/SKILL.md")"
              [ -z "$declared_name" ] && declared_name="$skill_name"

              # description 추출 (128자 제한, Codex CLI에 공식 제한 없음 — UI 안전 마진)
              short_desc="$(${pkgs.gawk}/bin/awk '
                BEGIN { in_fm = 0; mode = ""; desc = "" }
                /^---[[:space:]]*$/ { if (in_fm == 0) { in_fm = 1; next } else { exit } }
                in_fm != 1 { next }
                mode == "" && /^description:[[:space:]]*\|[[:space:]]*$/ { mode = "block"; next }
                mode == "" && /^description:[[:space:]]*>[[:space:]]*-?[[:space:]]*$/ { mode = "block"; next }
                mode == "" && /^description:[[:space:]]*/ {
                  line = $0; sub(/^description:[[:space:]]*/, "", line);
                  gsub(/^[[:space:]]+|[[:space:]]+$/, "", line);
                  print line; exit
                }
                mode == "block" {
                  if ($0 ~ /^[A-Za-z0-9_-]+:[[:space:]]*/) { print desc; exit }
                  line = $0; sub(/^[[:space:]]+/, "", line);
                  gsub(/^[[:space:]]+|[[:space:]]+$/, "", line);
                  if (line == "") next;
                  if (desc == "") desc = line; else desc = desc " " line
                }
                END { if (mode == "block" && desc != "") print desc }
              ' "$source_skill_dir/SKILL.md")"
              # KEEP IN SYNC: syncing-codex-harness/references/sync.sh
              short_desc="''${short_desc:0:128}"
              [ -z "$short_desc" ] && short_desc="Project skill for nixos-config workflows"

              # display_name: kebab-case → Title Case
              display_name="$(echo "$declared_name" | tr '-' ' ' | ${pkgs.gawk}/bin/awk '{
                for (i = 1; i <= NF; i++) $i = toupper(substr($i, 1, 1)) substr($i, 2)
                print
              }')"

              # 알려진 약어 보정 (KEEP IN SYNC: syncing-codex-harness/references/sync.sh)
              display_name="$(echo "$display_name" | sed 's/\bSsh\b/SSH/g; s/\bMacos\b/macOS/g; s/\bMinipc\b/MiniPC/g')"

              # yaml 파일 작성 (YAML 특수문자 이스케이프)
              escaped_display="$(echo "$display_name" | sed 's/\\/\\\\/g; s/"/\\"/g')"
              escaped_desc="$(echo "$short_desc" | sed 's/\\/\\\\/g; s/"/\\"/g')"

              cat > "$yaml_file" <<YAML
        interface:
          display_name: "$escaped_display"
          short_description: "$escaped_desc"
          default_prompt: "Use \$$declared_name to help with this task in nixos-config."
        YAML
            done

            # ── 깨진/고아 심링크 정리 ──
            if [ -d "$TARGET_SKILLS" ]; then
              for target_dir in "$TARGET_SKILLS"/*/; do
                [ -d "$target_dir" ] || continue
                skill_name="$(basename "$target_dir")"
                if [ ! -d "$SOURCE_SKILLS/$skill_name" ]; then
                  echo "Removing orphan projected skill: .agents/skills/$skill_name"
                  $DRY_RUN_CMD rm -rf "$target_dir"
                fi
              done
            fi
      '';
}
