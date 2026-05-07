# Islands Dark VSCode theme integration.
# Keep source packaging, font packaging, and upstream CSS contract guards out of
# the main HM module.
{
  lib,
  pkgs,
  source,
}:

let
  packageJson = builtins.fromJSON (builtins.readFile "${source}/package.json");
  settingsJson = builtins.fromJSON (builtins.readFile "${source}/settings.json");

  expectedPublisher = "bwya77";
  expectedName = "islands-dark";
  uniqueId = "${expectedPublisher}.${expectedName}";
  packageVersion =
    if packageJson.publisher != expectedPublisher || packageJson.name != expectedName then
      throw "Unexpected Islands Dark extension id: ${packageJson.publisher}.${packageJson.name}"
    else if builtins.match "[0-9]+\\.[0-9]+\\.[0-9]+" packageJson.version == null then
      throw "Unexpected Islands Dark extension version: ${packageJson.version}"
    else
      packageJson.version;

  rawStylesheet =
    if builtins.hasAttr "custom-ui-style.stylesheet" settingsJson then
      settingsJson."custom-ui-style.stylesheet"
    else
      throw "Islands Dark settings.json is missing custom-ui-style.stylesheet";

  stylesheet =
    if builtins.isAttrs rawStylesheet then
      rawStylesheet
    else
      throw "Islands Dark custom-ui-style.stylesheet must be a JSON object";

  assertCssFragment =
    role: text:
    let
      lowerText = lib.toLower text;
      blockedExternal = lib.any (needle: lib.hasInfix needle lowerText) [
        "@import"
        "url("
        "http://"
        "https://"
        "file://"
      ];
      blockedStructure = lib.any (needle: lib.hasInfix needle text) [
        "{"
        "}"
        ";"
        "/*"
        "*/"
        "\n"
        "\r"
      ];
    in
    if blockedExternal || blockedStructure then
      throw "Islands Dark stylesheet contains blocked CSS ${role}: ${text}"
    else
      text;

  unsupportedStylesheetEntries = lib.filterAttrs (
    selector: rules: !(builtins.isAttrs rules) && !(lib.hasPrefix "//" selector)
  ) stylesheet;

  cssRules =
    if unsupportedStylesheetEntries != { } then
      throw "Islands Dark stylesheet contains unsupported non-object entries: ${lib.concatStringsSep ", " (builtins.attrNames unsupportedStylesheetEntries)}"
    else
      lib.filterAttrs (
        selector: rules: builtins.isAttrs rules && !(lib.hasPrefix "//" selector)
      ) stylesheet;

  cssValueToString =
    value:
    let
      type = builtins.typeOf value;
    in
    if type == "string" then
      assertCssFragment "value" value
    else if type == "int" || type == "float" || type == "bool" then
      toString value
    else
      throw "Islands Dark stylesheet contains unsupported CSS value type: ${type}";

  # Nix JSON parsing stores objects as attrsets, so selector/property source order is not preserved.
  # Keep this path only as a contract guard for self-contained declarations.
  cssText =
    let
      text = builtins.concatStringsSep "\n" (
        lib.mapAttrsToList (selector: rules: ''
          ${assertCssFragment "selector" selector} {
          ${builtins.concatStringsSep "\n" (
            lib.mapAttrsToList (
              prop: value: "  ${assertCssFragment "property" prop}: ${cssValueToString value};"
            ) rules
          )}
          }
        '') cssRules
      );
    in
    if cssRules == { } then
      throw "Islands Dark stylesheet does not contain any CSS rules"
    else if !(lib.hasInfix "--islands-panel-radius" text) then
      throw "Islands Dark stylesheet is missing expected --islands-panel-radius marker"
    else
      text;

  cssFile = pkgs.writeText "islands-dark-vscode.css" cssText;

  extension = pkgs.stdenvNoCC.mkDerivation {
    pname = "vscode-extension-${expectedPublisher}-${expectedName}";
    version = packageVersion;
    src = source;

    installPhase = ''
      runHook preInstall

      extension_dir="$out/share/vscode/extensions/${uniqueId}"
      mkdir -p "$extension_dir"
      cp package.json "$extension_dir/"
      cp -r themes "$extension_dir/"
      if [ -f icon.png ]; then
        cp icon.png "$extension_dir/"
      fi

      # Force evaluation/build of the generated CSS contract guard. The signed
      # VSCode app bundle is intentionally not patched here.
      test -s ${cssFile}

      runHook postInstall
    '';

    passthru = {
      islandsDarkCssFile = cssFile;
      vscodeExtUniqueId = uniqueId;
      vscodeExtPublisher = expectedPublisher;
      vscodeExtName = expectedName;
    };
  };

  fonts = {
    bearSansUi = pkgs.stdenvNoCC.mkDerivation {
      pname = "bear-sans-ui";
      version = packageVersion;
      src = "${source}/fonts";

      installPhase = ''
        runHook preInstall

        mkdir -p "$out/share/fonts/opentype"
        cp *.otf "$out/share/fonts/opentype/"

        runHook postInstall
      '';
    };
  };

in
{
  inherit
    cssFile
    extension
    fonts
    ;
}
