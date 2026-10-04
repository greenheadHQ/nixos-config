# nixos-config

[한국어](./README.ko.md)

My Nix configuration for a personal Mac, a work Mac, and a NixOS home server. I keep them here to make the environments consistent and easier to rebuild.

The Macs use nix-darwin, and Home Manager manages user settings on both macOS and NixOS. Shell, editor, and CLI settings are shared; desktop apps and server services live in separate modules.

These configurations include my usernames, paths, and encrypted secrets. If you're borrowing from them, start with the individual modules.

## How it's organized

[flake.nix](./flake.nix) defines the two Apple Silicon Macs and the x86_64 Linux server. Host roles distinguish personal, work, and server settings—for example, personal Mac apps can be kept off the work machine.

| Location | Contents |
| --- | --- |
| [modules/shared](./modules/shared/) | Shell, Git, Neovim, tmux, and other settings used across machines |
| [modules/darwin](./modules/darwin/) | macOS preferences, desktop apps, and automation |
| [modules/nixos](./modules/nixos/) | NixOS system settings and home server services |
| [hosts](./hosts/) | Hardware and disk configuration |
| [libraries/constants.nix](./libraries/constants.nix) | Shared host, network, and path values |

Nix manages system packages and configuration. [mise](./modules/shared/programs/mise/) manages Node.js and its package managers, so each project can select its own versions. Some Mac apps are declared through [Homebrew](./modules/darwin/programs/homebrew.nix).

## A few parts to explore

**Mac automation.** [Hammerspoon](./modules/darwin/programs/hammerspoon/) handles input switching, terminal shortcuts while using Korean input, and opening Ghostty in the current Finder folder. [Folder actions](./modules/darwin/programs/folder-actions/) use launchd to compress videos and convert them to GIFs. On the personal Mac, they also upload screenshots to Immich.

**Home server and Anki.** The MiniPC configuration includes Immich for photos, Karakeep for bookmarks, and Copyparty for files. Services are configured through [homeserver options](./modules/nixos/options/homeserver.nix) and enabled in the [NixOS configuration](./modules/nixos/configuration.nix). The [Anki host](./modules/nixos/programs/anki-host/README.md) includes sync, backups, and an MCP server for reading and editing notes from chat clients.

**Claude Code and Codex.** Their [Claude](./modules/shared/programs/claude/) and [Codex](./modules/shared/programs/codex/) modules keep configuration, hooks, and shared skills in the repository. [Repository-specific skills](./.claude/skills/) hold maintenance instructions for this environment, so those instructions travel with the configuration too.

## Working on the configuration

Run the checks from the repository root:

```sh
nix develop --command bash tests/run-all-tests.sh
```

The [test runner](./tests/run-all-tests.sh) is also used by [CI](./.github/workflows/check.yml). Git hook behavior is documented in the [Nix maintenance notes](./.claude/skills/understanding-nix/references/features.md#pre-commit-hooks), with commands and conditions in [lefthook.yml](./lefthook.yml).

On machines already set up with this configuration, `nrs` previews and applies changes. Maintenance notes cover [macOS](./.claude/skills/managing-macos/SKILL.md), [the MiniPC](./.claude/skills/managing-minipc/SKILL.md), and [secrets](./.claude/skills/managing-secrets/SKILL.md). Most of these notes and the code comments are in Korean.

[MIT license](./LICENSE).
