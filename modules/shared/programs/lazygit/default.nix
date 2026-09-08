# lazygit 설정 (delta diff renderer 통합)
{ ... }:
{
  programs.lazygit = {
    enable = true;
    settings = {
      # lazygit 0.64.0에서 git.pagers -> git.diffRenderers, pager -> command로 개명됨
      git.diffRenderers = [
        {
          colorArg = "always";
          # DELTA_FEATURES="" : gitconfig의 features(interactive)를 리셋하여
          # side-by-side와 navigate를 비활성화 (lazygit diff 패널이 좁아서 부적합)
          command = "env DELTA_FEATURES= delta --paging=never";
        }
      ];
    };
  };
}
