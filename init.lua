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
require 'core.gitsigns' -- change signs in the sign column, ]h [h, hunk stage/reset
require 'core.pytest' -- <leader>nr pytest -v -k <nearest test/function> in the terminal
require 'core.pyimports' -- :Rename, netrw R, :FixImports update imports of a moved module
require 'core.hive' -- <leader>h*: HiveQL in .sql/.hql, schema browser, completion (needs vim.g.hive)
require 'core.lualine' -- 'statusline' + LSP breadcrumbs
require 'core.tabline' -- 'tabline' for tab pages
require 'core.cursorword' -- highlight other occurrences of the word under the cursor
require 'core.notebook' -- BufReadCmd *.ipynb -> percent script, cells run in a Jupyter kernel
require 'core.session' -- restore last session per CWD when started with no file args

-- PYTHONBREAKPOINT lives here rather than in pydebug so `breakpoint()` still routes to
-- the debugger in a session where you never open a .py buffer.
vim.env.PYTHONBREAKPOINT = 'ipdb.set_trace'

-- Which debugger the python debug keys drive. Both bind <leader>b & co, so load one:
--   'dap'  -> core.dap + core.dapview: DAP client for debugpy (conda install debugpy)
--   'ipdb' -> core.pydebug: ipdb in the terminal split, no debugpy needed
vim.g.python_debugger = vim.g.python_debugger or 'dap'

vim.api.nvim_create_autocmd('FileType', {
  pattern = 'python',
  once = true,
  callback = function()
    require(vim.g.python_debugger == 'ipdb' and 'core.pydebug' or 'core.dap')
  end,
})

vim.api.nvim_create_autocmd('FileType', {
  pattern = 'markdown',
  once = true,
  callback = function()
    require 'core.mdformat'
  end,
})
