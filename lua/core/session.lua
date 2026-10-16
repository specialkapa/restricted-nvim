-- Remember the last session per working directory, using only the built-in :mksession.
--
-- On exit the window layout, tabs and open files are written to
--   stdpath('state')/sessions/<cwd with / replaced by %>.vim
-- and `nvim` started with no file arguments in that same directory restores them.
-- `nvim somefile` or `nvim -` never restores, so opening a single file stays fast.
--
--   <leader>qs  restore the session for the CWD (e.g. after starting with a file)
--   <leader>qd  don't save a session when quitting this time
--
-- Terminals, netrw, the debugger views and other scratch windows are closed before
-- saving: :mksession can't recreate their contents, so they'd come back as empty splits.

local M = {}

local DIR = vim.fn.stdpath 'state' .. '/sessions/'

-- No 'blank' (empty windows), 'terminal', 'options' or 'localoptions': options belong
-- to this config, and a session that remembers them goes stale the moment it changes.
vim.opt.sessionoptions = { 'buffers', 'curdir', 'folds', 'help', 'tabpages', 'winsize' }

local enabled = true

---Session file for the current working directory.
local function file()
  return DIR .. vim.fn.getcwd():gsub('[\\/:]', '%%') .. '.vim'
end

---Does this buffer hold something :mksession can bring back? Help is fine; anything
---with another 'buftype' (terminal, nofile, prompt, quickfix) or no name is not.
local function restorable(buf)
  local bt = vim.bo[buf].buftype
  return (bt == '' or bt == 'help') and vim.api.nvim_buf_get_name(buf) ~= '' and vim.bo[buf].filetype ~= 'netrw'
end

function M.save()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if not restorable(vim.api.nvim_win_get_buf(win)) then
      pcall(vim.api.nvim_win_close, win, true) -- fails on the last window; that's fine
    end
  end
  -- Nothing worth restoring: drop the old session rather than overwrite it with an empty one.
  local any = vim.iter(vim.api.nvim_list_bufs()):any(function(b)
    return vim.bo[b].buflisted and restorable(b)
  end)
  if not any then
    return
  end
  vim.fn.mkdir(DIR, 'p')
  vim.cmd('silent! mksession! ' .. vim.fn.fnameescape(file()))
end

function M.load()
  local f = file()
  if vim.fn.filereadable(f) == 0 then
    vim.notify('No session for ' .. vim.fn.getcwd(), vim.log.levels.INFO)
    return
  end
  vim.cmd('silent! source ' .. vim.fn.fnameescape(f))
end

local group = vim.api.nvim_create_augroup('core.session', { clear = true })

vim.api.nvim_create_autocmd('VimEnter', {
  group = group,
  -- nested, so the restored buffers fire FileType/BufRead* and get LSP, notebook, etc.
  nested = true,
  callback = function()
    if vim.fn.argc() == 0 and not vim.g.started_with_stdin then
      if vim.fn.filereadable(file()) == 1 then
        M.load()
      end
    end
  end,
})

-- Reading from stdin (`cmd | nvim -`) leaves argc() at 0, so remember it separately.
vim.api.nvim_create_autocmd('StdinReadPre', {
  group = group,
  callback = function()
    vim.g.started_with_stdin = true
  end,
})

vim.api.nvim_create_autocmd('VimLeavePre', {
  group = group,
  callback = function()
    if enabled then
      M.save()
    end
  end,
})

vim.keymap.set('n', '<leader>qs', M.load, { desc = 'Restore session for CWD' })
vim.keymap.set('n', '<leader>qd', function()
  enabled = false
  vim.notify 'Session will not be saved on exit'
end, { desc = "Don't save session on exit" })

return M
