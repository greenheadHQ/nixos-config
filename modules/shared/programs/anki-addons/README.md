# Desktop Anki add-ons

AnkiWeb sync does not install desktop add-ons on another computer. This Home
Manager module pins the ten desktop add-ons in `sources.json` and applies them
to the existing macOS Anki installation. It does not install/upgrade Anki,
enable `programs.anki`, or open/change `prefs21.db`, collections or sync accounts.
The MiniPC's `anki-host` service keeps its separate, patched AnkiConnect package.

The personal Mac enables this module; the work Mac imports it but leaves it off.
Opt in on another Mac with `programs.ankiAddons.enable = true`. The base path is
defined in `libraries/constants.nix`; a custom Anki `-b` directory can be selected
with `programs.ankiAddons.baseDirectory`. Linux desktop support is not wired in.

## Apply and ownership

Close Anki before `nrs`. Home Manager runs `anki-addons apply` after the write
boundary. If any Anki process owned by the user is running, activation prints
that deployment is deferred and leaves the add-ons untouched. After closing it,
run `anki-addons apply`. No automatic process termination or background retry.
Do not launch Anki while applying; the process guard is checked twice, but Anki
does not participate in the deployment lock.

Each add-on is a writable directory, not a symlink into the Nix store. Code and
default config come from the pinned package; `meta.json` preserves unrelated
keys while enforcing the declared `config` keys, enabled state and package
metadata. Previously declared config keys removed from Nix fall back to the
package defaults. GUI edits to declared keys are replaced on the next apply;
other runtime config keys remain local. Defaults and the declared custom
config overrides are shared across machines, not every transient GUI setting.
Never put API keys or other secrets in the Nix config.

Customize Keyboard Shortcuts disables the reviewer's `delete note` and the
Browser's `delete` shortcuts with `<nop>`. This leaves Command+Backspace available
for text editing without accidentally deleting a note. The deletion menus remain
available. This desktop setting is shared by local profiles and does not sync to
AnkiMobile.

`user_files` is seeded only when files are missing, then preserved on updates.
Other unknown runtime files and unmanaged add-ons are preserved. Removing an
entry from the complete declared add-on set removes only an add-on recorded in
`addons21/.nix-managed.json`; removing the module/setting `enable = false` does
not uninstall anything. For a smaller list, override the set with `lib.mkForce`.
An add-on's obsolete managed code files are removed when its package changes.
Existing symlinked trees are refused instead of following another manager's
links. Interrupted transactions require explicit recovery before another apply.

Anki's `update_enabled = false` keeps managed add-ons out of automatic update
prompts/default selections. A user can still explicitly select an update in
Anki; the next apply restores the pinned code. Perform durable updates in Nix.

## Sources and updates

`sources.json` records the official source URL, archive SHA-256 and modification
timestamp. `p=260902` requests the distribution for Anki 26.09.2; **it is not an
immutable add-on version URL**. The initial archives match the installed code
byte for byte. We use those distributions rather than upstream HEAD or a
different nixpkgs revision, preserving bundled JavaScript and vendor files.

Note Linker uses the upstream `v.2026.08.10` release asset after AnkiWeb replaced
its distribution. That asset is byte-identical to the original pinned archive;
the hash and modification timestamp remain unchanged.

The Note Linker package applies one local rendering patch: markers inside
`pre`, `code`, `script`, `style` and `textarea` remain literal. This prevents
code examples from becoming links before syntax highlighting runs. Its
graph/index extraction is unchanged. The patch is applied with zero fuzz;
review it again when updating the pinned distribution.

If AnkiWeb replaces a distribution, a fresh build fails on the hash mismatch
rather than silently updating. Existing Nix generations/cache retain the old
package while rooted, but AnkiWeb does not guarantee old downloads. Preserve
the package closure in a Nix cache for long-term/offline recovery. A Nix hash
alone is not a permanent source archive. Do not blindly replace the hash after
a mismatch: download/review the new distribution, compare its metadata and
code, test it with the desktop Anki version, then update URL/hash/mod together.

Build all packages independently of Anki:

```sh
nix develop --command nix build .#ankiDesktopAddons --no-link
```

## Backups and rollback

Before a changed apply, the whole previous `addons21` tree is retained under
`Anki2/.nix-anki-addons/<backup-id>` with private parent permissions. The ID is
printed after deployment. Identical applies do not create another backup.
Backups are not automatically pruned and are local, not synced by AnkiWeb.

```sh
anki-addons list-backups --json
anki-addons restore <backup-id>
anki-addons recover
```

`list-backups` reads the local snapshots without creating directories, a lock,
or config, and works while Anki is running. Without `--json`, it prints a short
ID/size/add-on-count list. The JSON contract is:

```json
{
  "schema_version": 1,
  "kind": "anki_addon_backups",
  "collection_data_included": false,
  "backups": [
    {
      "id": "<backup-id>",
      "created_at": null,
      "created_at_source": "not_recorded",
      "size_bytes": 1234,
      "restore_scope": "whole_addons21_tree",
      "compatibility": "not_evaluated",
      "addons": [
        {"id": "123", "name": "Example", "package_mod": 1780000000, "managed": true}
      ]
    }
  ]
}
```

Backups are ordered by ID, not time. Creation time was not recorded; directory
mtime is not a substitute. `package_mod` is the metadata modification timestamp,
not a semantic version, and is `null` when absent or not an integer. Names can
also be `null`. `managed` reflects the snapshot's ownership record, not the
current declaration. Size counts regular-file bytes in the entire snapshot;
the add-on list includes directories identified by code, metadata or ownership.
The output excludes file bodies and runtime/config values. Symlinks, special
files and malformed metadata are refused with a generic error rather than
partial or misleading inventory. Listing takes no write lock, so retry if a
concurrent apply/recovery makes the scan fail. Inventory does not establish
that a snapshot is compatible with the current Anki version.

`restore` restores the entire add-on snapshot (including unmanaged add-ons and
runtime files), preserving the replaced tree as a new backup. The original
snapshot remains available. It does not restore cards. `recover` is only for
an apply interrupted between the directory renames: it restores the pre-apply
tree and retains an already installed replacement as another backup. Review
the recovered tree before reapplying. A subsequent apply enforces the currently
installed Nix declaration again; use the previous Nix generation/declaration
for a durable code rollback. Runtime data migrations may require restoring the
matching snapshot too.

## Verification

```sh
nix develop --command bash tests/run-anki-addons-tests.sh
nix develop --command bash tests/run-eval-tests.sh
```

Filesystem tests cover adoption, state preservation, removal, reapplication,
rollback, process guards, lock contention and failed/interrupted swaps. They
use temporary directories and never the user's collection. Runtime acceptance
must additionally load the selected distributions in a separate Anki `-b`
directory without a sync login and check editor/reviewer functionality.

For a compatibility check, select one actual Anki version and one pinned add-on
set. Use a disposable `-b` directory, never sign in to AnkiWeb, and use synthetic
notes. For GUI editing, follow the [hosting-anki Mac GUI safety boundary](../../../../.claude/skills/hosting-anki/SKILL.md#mac-gui-자동화-안전-경계):
use manual or API operations for the restricted editor/Browse windows until
their isolated A/B verification passes.

Run at least these checks in normal mode with the selected add-ons loaded:

1. Start Anki and confirm the selected add-ons load without an error.
2. Add/edit a synthetic note and exercise representative editor add-on actions.
3. Review question → answer → grade → next card, including representative
   reviewer add-on actions such as a Note Linker preview or a configured control.

Keep the acceptance summary for the exact combination tested in the relevant
PR or issue; keep only personal or sensitive diagnostic material private:

| Item | Recorded value |
| --- | --- |
| Run date | `<date with timezone>` |
| Anki / OS | `<actual Anki version>` / `<OS version>` |
| Source manifest | `<SHA-256 of sources.json>` |
| Packages actually loaded | `<add-on IDs and package-tree SHA-256 hashes; state the hash method>` |
| Representative note types / enabled-config combination | `<exact note types/templates; enabled/disabled add-on IDs; non-secret config combination identifier>` |
| Normal startup | `unverified` / `pass` / `fail`; `<evidence>` |
| Synthetic-note editing | `unverified` / `pass` / `fail`; `<actions and evidence>` |
| Review sequence and representative actions | `unverified` / `pass` / `fail`; `<actions and evidence>` |
| File-management tests | `<separate result and run date>` |
| Qt-free Note Linker checks | `<separate result and run date>` |
| Linux Anki-engine checks, if performed | `<separate result and run date>` |

Record the actual package trees, including local patches; an upstream archive
hash alone does not identify the code loaded. A NAR SHA-256 from `nix hash path`
is one option for a Nix package tree. The file-management, Qt-free Note Linker
and Linux engine results do not count as GUI checks. Leave unexecuted checks
`unverified`; this record covers only the selected version/package combination,
note types and config, not every Anki version or add-on combination. A stock
Basic result does not verify the managed 학습 Basic renderers.
