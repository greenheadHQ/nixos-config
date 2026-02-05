-- markdownlint-cli2: 홈 디렉토리 설정 파일 명시적 지정
-- markdownlint-cli2는 프로젝트 디렉토리만 검색하므로 --config 필요
return {
  {
    "mfussenegger/nvim-lint",
    opts = {
      linters = {
        ["markdownlint-cli2"] = {
          prepend_args = { "--config", vim.fn.expand("~/.markdownlint.jsonc") },
        },
      },
    },
  },
}
