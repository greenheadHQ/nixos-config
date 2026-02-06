# lazygit 설정 (delta pager 통합)
{ ... }:
{
  programs.lazygit = {
    enable = true;
    settings = {
      git.pagers = [
        {
          colorArg = "always";
          # DELTA_FEATURES="" : gitconfig의 features(interactive)를 리셋하여
          # side-by-side와 navigate를 비활성화 (lazygit diff 패널이 좁아서 부적합)
          pager = "env DELTA_FEATURES= delta --paging=never";
        }
      ];
    };
  };
}
