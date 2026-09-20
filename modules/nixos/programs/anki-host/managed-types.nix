# Build the candidate content from reviewable sources. This does not enroll it,
# edit a collection, or make newly deployed content an approved restore target.
{ pkgs }:
pkgs.runCommand "anki-managed-types" { nativeBuildInputs = [ pkgs.python3 ]; } ''
  mkdir source
  cp -r ${./managed-types} source/managed-types
  cp -r ${./sync-addon} source/sync-addon
  mkdir source/code-highlighting
  cp -r ${./code-highlighting/dist} source/code-highlighting/dist
  python3 source/managed-types/build.py source "$out"
''
