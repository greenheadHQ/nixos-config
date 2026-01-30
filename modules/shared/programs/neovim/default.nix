# Neovim 설정
{
  config,
  pkgs,
  lib,
  ...
}:

{
  programs.neovim = {
    enable = true;
    defaultEditor = true; # EDITOR=nvim
    viAlias = true; # vi → nvim
    vimAlias = true; # vim → nvim

    plugins = with pkgs.vimPlugins; [
      catppuccin-nvim
      nvim-surround
    ];

    initLua = ''
      -- 테마
      require("catppuccin").setup({ flavour = "mocha" })
      vim.cmd.colorscheme "catppuccin"

      -- nvim-surround
      require("nvim-surround").setup()

      -- 기본 옵션
      vim.opt.number = true
      vim.opt.relativenumber = true
      vim.opt.clipboard = "unnamedplus"
      vim.opt.copyindent = true
      vim.opt.termguicolors = true

      -- 키 매핑 (기존 vim 설정 마이그레이션)
      vim.keymap.set("n", "H", "^", { desc = "줄 첫 글자로 이동" })
      vim.keymap.set("n", "L", "$", { desc = "줄 끝으로 이동" })
    '';
  };
}
