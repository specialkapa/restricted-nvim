-- Neovim config for restricted environments: no plugin manager, no plugins, no GitHub.
-- Everything under lua/core/ uses only built-in Neovim APIs.
--
-- Load order matters:
--   * options/keymaps first, so <leader> is set before anything binds to it
--   * lsp, pyformat, terminal register autocmds that must exist before the events fire
--   * mdformat and pydebug are deferred until the relevant filetype appears

require 'core.options'
require 'core.keymaps'

require 'core.clipboard' -- wires up a clipboard provider if none exists
require 'core.completion' -- sets 'completeopt' globally
require 'core.lsp' -- FileType python -> vim.lsp.start
require 'core.pyformat' -- BufWritePost *.py -> ruff on modified hunks
require 'core.terminal' -- <leader>tt, TermOpen mappings
require 'core.explorer' -- <leader>E reveal file in netrw
require 'core.peek' -- <leader>pd peek definition
require 'core.picker' -- <leader>sf / sg / sw / sb / /
require 'core.gitblame' -- <leader>gb
require 'core.lualine' -- 'statusline' + LSP breadcrumbs
require 'core.tabline' -- 'tabline' for tab pages

-- PYTHONBREAKPOINT lives here rather than in pydebug so `breakpoint()` still routes to
-- the debugger in a session where you never open a .py buffer.
vim.env.PYTHONBREAKPOINT = 'ipdb.set_trace'

vim.api.nvim_create_autocmd('FileType', {
  pattern = 'python',
  once = true,
  callback = function()
    require 'core.pydebug'
  end,
})

vim.api.nvim_create_autocmd('FileType', {
  pattern = 'markdown',
  once = true,
  callback = function()
    require 'core.mdformat'
  end,
})
