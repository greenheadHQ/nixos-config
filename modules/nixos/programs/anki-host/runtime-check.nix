# Validate the installed addons against the cached Anki package. Keep this
# separate from Anki itself so changing our tests never invalidates its cache.
{
  pkgs,
  addons ? import ./addons.nix { inherit pkgs; },
}:
let
  python = pkgs.python3.withPackages (ps: [ ps.pytest ]);
in
pkgs.runCommand "anki-host-runtime-check"
  {
    ANKICONNECT_SOURCE = "${addons.connect}/share/anki/addons/anki-connect";
    ANKI_HOST_HELPER_SOURCE = "${addons.helper}/share/anki/addons/anki_host_sync";
    ANKI_HOST_RECOVERY_SOURCE = "${./files/recover-fields.py}";
    ANKI_NOTE_LINK_FIXTURES = "${../../../../tests/fixtures/anki-note-link}";
    ANKI_EXPECTED_VERSION = pkgs.anki.version;
    ANKI_TEST_MODE = "1";
    QT_QPA_PLATFORM = "offscreen";
    PYTEST_DISABLE_PLUGIN_AUTOLOAD = "1";
  }
  ''
    # Only this small directory is an input; unrelated repository changes must
    # not rerun the backend checks. Every test creates its own empty collection.
    cp -r ${../../../../tests/anki-runtime} tests
    chmod -R u+w tests
    ${python}/bin/python - <<'PY'
    import site
    import sys

    site.addsitedir("${pkgs.anki.lib}/${pkgs.python3.sitePackages}")
    from anki.buildinfo import version
    import pytest

    print(f"Checking installed addons with Anki {version}", flush=True)
    sys.exit(pytest.main(["-q", "-p", "no:cacheprovider", "tests"]))
    PY
    mkdir -p "$out"
    printf '%s\n' 'Anki ${pkgs.anki.version}: runtime checks passed' > "$out/result"
  ''
