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
other runtime config keys remain local. Defaults and the two existing custom
config overrides are shared across machines, not every transient GUI setting.
Never put API keys or other secrets in the Nix config.

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

`sources.json` records the official AnkiWeb URL, archive SHA-256 and modification
timestamp. `p=260902` requests the distribution for Anki 26.09.2; **it is not an
immutable add-on version URL**. The initial archives match the installed code
byte for byte. We use those distributions rather than upstream HEAD or a
different nixpkgs revision, preserving bundled JavaScript and vendor files.

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
anki-addons restore <backup-id>
anki-addons recover
```

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
