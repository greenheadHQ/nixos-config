-- ============================================================================
-- nvim-dap: JS/TS 서버사이드 디버깅 (attach)
-- ============================================================================
-- LazyVim의 dap.core + lang.typescript extra가 pwa-node 어댑터와
-- launch/attach(processId picker) 설정을 이미 제공한다.
-- 여기서는 "이미 --inspect로 떠 있는 Node/Next.js 프로세스"에 포트로 attach하는
-- 설정을 추가한다 (picker보다 명확한 서버 디버깅 경로).
--
-- 사용:
--   1) 프로젝트에서 `node --inspect=127.0.0.1:9229 ...` (또는 dev 서버 --inspect) 실행
--   2) nvim에서 <leader>dc (continue) → "Attach to :9229 (--inspect)" 선택
--
-- 보안: inspector는 반드시 127.0.0.1에 바인딩한다. 이 호스트는 tailscale0이
-- trusted interface라 0.0.0.0:9229는 tailnet 전체에 디버그 제어를 노출한다.
return {
  {
    "mfussenegger/nvim-dap",
    optional = true, -- dap.core extra가 없으면 안전하게 무시
    opts = function()
      local dap = require("dap")
      -- LazyVim lang.typescript extra가 pwa-node 어댑터를 등록하며
      -- require("dap.ext.vscode").type_to_filetypes["pwa-node"]에 js filetype 목록을 채운다.
      -- 그 값을 재사용해 목록을 두 곳에 복제하지 않는다(upstream 드리프트 방지).
      -- 아직 비어 있으면(로드 순서) 동일 목록으로 폴백한다.
      local js_filetypes = require("dap.ext.vscode").type_to_filetypes["pwa-node"]
        or { "typescript", "javascript", "typescriptreact", "javascriptreact" }
      for _, ft in ipairs(js_filetypes) do
        dap.configurations[ft] = dap.configurations[ft] or {}
        table.insert(dap.configurations[ft], {
          type = "pwa-node",
          request = "attach",
          name = "Attach to :9229 (--inspect)",
          address = "127.0.0.1",
          port = 9229,
          cwd = "${workspaceFolder}",
          sourceMaps = true,
          restart = true,
          -- Next.js dev는 SSR을 child process로 실행 → 자식까지 따라가야 breakpoint 적용
          autoAttachChildProcesses = true,
          skipFiles = { "<node_internals>/**", "**/node_modules/**" },
          resolveSourceMapLocations = {
            "${workspaceFolder}/**",
            "!**/node_modules/**",
          },
        })
      end
    end,
  },
}
