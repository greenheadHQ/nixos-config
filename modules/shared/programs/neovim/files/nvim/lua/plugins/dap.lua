-- ============================================================================
-- nvim-dap: JS/TS 서버사이드 디버깅 (attach)
-- ============================================================================
-- LazyVim의 dap.core + lang.typescript extra가 pwa-node 어댑터와
-- launch/attach(processId picker) 설정을 이미 제공한다.
-- 여기서는 "이미 --inspect로 떠 있는 Node/Next.js 프로세스"에 포트로 attach하는
-- 설정을 추가한다 (picker보다 명확한 서버 디버깅 경로).
--
-- 플랫폼: dap.core import는 lazy.lua에서 공통(darwin+nixos)으로 두어 공유
-- lazy-lock.json의 DAP pin을 보존한다. 실제 로드는 여기서 cond(Linux)로 제한한다 —
-- js-debug adapter가 Linux extraPackages 전용이라 macOS에서는 로드해도 빈 DAP UI만
-- 노출되기 때문이다 (macOS는 VSCode로 디버깅). cond=false는 설치(pin)는 두고 로드만 막는다.
--
-- 사용:
--   1) 프로젝트에서 `node --inspect=127.0.0.1:9229 ...` (또는 dev 서버 --inspect) 실행
--   2) nvim에서 <leader>dc (continue) → "Attach to :9229 (--inspect)" 선택
--
-- 보안: inspector는 반드시 127.0.0.1에 바인딩한다. 이 호스트는 tailscale0이
-- trusted interface라 0.0.0.0:9229는 tailnet 전체에 디버그 제어를 노출한다.
local is_linux = function()
  return vim.fn.has("linux") == 1
end

return {
  {
    "mfussenegger/nvim-dap",
    optional = true, -- dap.core extra가 없으면 안전하게 무시
    cond = is_linux,
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
  -- dap.core가 가져오는 UI/보조 플러그인도 macOS 로드를 막는다 (lock pin은 공통 import로 보존).
  { "rcarriga/nvim-dap-ui", optional = true, cond = is_linux },
  { "theHamsta/nvim-dap-virtual-text", optional = true, cond = is_linux },
}
