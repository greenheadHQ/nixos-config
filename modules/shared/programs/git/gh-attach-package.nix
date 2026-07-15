# gh-attach — GitHub user-attachments 업로드 gh 확장 (fork 공급 원점, #1118)
# self-fix 시: fork에 커밋 → rev + src hash 갱신 (Go 의존성 변경 시 vendorHash도) → nrs
{ pkgs }:
pkgs.buildGoModule {
  pname = "gh-attach";
  version = "0.3.0";

  src = pkgs.fetchFromGitHub {
    owner = "greenheadHQ";
    repo = "gh-attach";
    rev = "b138347ff60da0907ae0942d2c501a54f308e736"; # v0.3.0
    hash = "sha256-hdgdIlAcumXtiNc3dMK/gk30M2JTbhkccj6x6rMG7y8=";
  };

  vendorHash = "sha256-Kdqt/hM0mYo9CER5AmBrV5RhnT9x/2Oj+vQH0wrVw74=";

  ldflags = [
    "-s"
    "-w"
  ];

  meta = {
    description = "GitHub user attachment upload CLI for gh";
    homepage = "https://github.com/greenheadHQ/gh-attach";
    license = pkgs.lib.licenses.mit;
    mainProgram = "gh-attach";
  };
}
