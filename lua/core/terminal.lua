-- Toggleable terminal, no plugins.
--
-- Reproduces the one toggleterm behaviour actually used:
--   <leader>tt -> ToggleTerm size=20 direction=horizontal
-- plus start_in_insert, persist_mode, close_on_exit and hide_numbers.
--
-- Not reproduced: multiple numbered terminals, float/vertical directions, shading,
-- responsiveness breakpoints, :TermExec. Those are the parts of toggleterm that
-- genuinely need a plugin.

local HEIGHT = 20

local state = {
  buf = nil,
  mode = 'i', -- persist_mode: insert or normal, remembered across toggles
}

local function buf_valid()
  return state.buf ~= nil and vim.api.nvim_buf_is_valid(state.buf)
end

---The window currently displaying the terminal, or nil.
local function find_win()
  if not buf_valid() then
    return nil
  end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(win) == state.buf then
      return win
    end
  end
  return nil
end

local function open()
  vim.cmd('botright ' .. HEIGHT .. 'split')
  local win = vim.api.nvim_get_current_win()

  if buf_valid() then
    vim.api.nvim_win_set_buf(win, state.buf)
  else
    -- :terminal spawns 'shell'. On linux that is your login shell; on windows it is
    -- powershell/cmd. Do NOT force /bin/bash in options.lua if you share that file
    -- with a windows machine.
    vim.cmd 'terminal'
    state.buf = vim.api.nvim_get_current_buf()
    -- close_on_exit: drop the buffer when the shell exits so the next toggle is fresh.
    vim.api.nvim_create_autocmd('TermClose', {
      buffer = state.buf,
      once = true,
      callback = function()
        state.buf = nil
      end,
    })
  end

  -- hide_numbers, and a bare gutter to match toggleterm's on_open.
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = 'no'
  vim.wo[win].spell = false

  if state.mode == 'i' then
    vim.cmd 'startinsert'
  end
end

local function close(win)
  -- Record the mode before hiding, so reopening lands you back where you were.
  state.mode = vim.fn.mode():sub(1, 1) == 't' and 'i' or 'n'
  vim.api.nvim_win_hide(win)
end

local function toggle()
  local win = find_win()
  if win then
    close(win)
  else
    open()
  end
end

vim.keymap.set({ 'n', 't' }, '<leader>tt', toggle, { desc = '[T]oggle [T]erminal' })
vim.api.nvim_create_user_command('ToggleTerm', toggle, { desc = 'Toggle the terminal split' })

---Open the terminal (if hidden) and send `cmd` to the running shell.
---opts.height temporarily grows the split -- a debugger needs more than 20 rows.
local function run(cmd, opts)
  opts = opts or {}
  local win = find_win()
  if not win then
    open()
    win = find_win()
  end
  if opts.height and win then
    vim.api.nvim_win_set_height(win, math.min(opts.height, vim.o.lines - 4))
    vim.api.nvim_set_current_win(win)
    vim.cmd 'startinsert'
  end
  local chan = state.buf and vim.bo[state.buf].channel
  if chan and chan > 0 then
    -- \r, not \n: a PTY wants a carriage return to submit, on every platform.
    vim.api.nvim_chan_send(chan, cmd .. '\r')
  end
end

---Send a register's contents to the program running in the terminal.
---Bound to <C-\><C-r>{reg}, deliberately NOT <C-r>: that is bash's reverse history
---search and readline would lose it. Mirrors the command line's <C-r>{reg}.
local function paste_register(bufnr)
  local ok, reg = pcall(vim.fn.getcharstr)
  if not ok or reg == nil or reg == '' then
    return
  end
  local text = vim.fn.getreg(reg)
  if text == nil or text == '' then
    return
  end
  -- Trailing newline would submit the line; you almost always want to keep typing.
  text = text:gsub('\n$', '')
  local chan = vim.bo[bufnr].channel
  if chan and chan > 0 then
    vim.api.nvim_chan_send(chan, text)
  end
end

-- Terminal-mode mappings. <C-h>/<C-l> are deliberately NOT mapped: those are tab
-- navigation here, and stealing them would also cost IPython's <C-l> clear-screen at a
-- debugger prompt. <C-j>/<C-k> cover the horizontal split; <C-w> reaches everything else.
vim.api.nvim_create_autocmd('TermOpen', {
  group = vim.api.nvim_create_augroup('user-terminal', { clear = true }),
  callback = function(args)
    local opts = { buffer = args.buf }
    vim.keymap.set('t', '<esc>', [[<C-\><C-n>]], opts)
    vim.keymap.set('t', 'jk', [[<C-\><C-n>]], opts)
    vim.keymap.set('t', '<C-j>', [[<Cmd>wincmd j<CR>]], opts)
    vim.keymap.set('t', '<C-k>', [[<Cmd>wincmd k<CR>]], opts)
    vim.keymap.set('t', '<C-w>', [[<C-\><C-n><C-w>]], opts)
    vim.keymap.set('t', [[<C-\><C-r>]], function()
      paste_register(args.buf)
    end, vim.tbl_extend('force', opts, { desc = 'Paste a register into the terminal' }))
    vim.opt_local.spell = false
  end,
})

return { toggle = toggle, run = run }
