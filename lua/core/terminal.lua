-- Toggleable terminal, no plugins.
--
-- Reproduces the one toggleterm behaviour actually used:
--   <leader>tt -> ToggleTerm size=20 direction=horizontal
-- plus start_in_insert, persist_mode, close_on_exit and hide_numbers.
--
-- Plus <leader>tv: a second, independent shell beside it that toggles with the first.
--
-- Not reproduced: multiple numbered terminals, float/vertical directions, shading,
-- responsiveness breakpoints, :TermExec. Those are the parts of toggleterm that
-- genuinely need a plugin.

local HEIGHT = 20

-- Colour of the rule above the terminal. `default` so a colorscheme can override it;
-- WinSeparator keeps it consistent with the vertical split borders.
local function set_hl()
  vim.api.nvim_set_hl(0, 'TermSeparator', { link = 'WinSeparator', default = true })
end
set_hl()
-- :colorscheme runs :hi clear, which drops groups it does not know about.
vim.api.nvim_create_autocmd('ColorScheme', { callback = set_hl })

local state = {
  buf = nil,
  buf2 = nil, -- the optional second shell beside it (<leader>tv)
  mode = 'i', -- persist_mode: insert or normal, remembered across toggles
}

local function valid(buf)
  return buf ~= nil and vim.api.nvim_buf_is_valid(buf)
end

local function buf_valid()
  return valid(state.buf)
end

---The window in this tab displaying `buf`, or nil.
local function win_of(buf)
  if not valid(buf) then
    return nil
  end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(win) == buf then
      return win
    end
  end
  return nil
end

---The window currently displaying the terminal, or nil.
local function find_win()
  return win_of(state.buf)
end

---Start a shell in the current window and remember its buffer as state[key].
local function new_term(key)
  -- :terminal spawns 'shell'. On linux that is your login shell; on windows it is
  -- powershell/cmd. Do NOT force /bin/bash in options.lua if you share that file
  -- with a windows machine.
  vim.cmd 'terminal'
  local buf = vim.api.nvim_get_current_buf()
  state[key] = buf
  -- close_on_exit: drop the buffer when the shell exits so the next toggle is fresh.
  vim.api.nvim_create_autocmd('TermClose', {
    buffer = buf,
    once = true,
    callback = function()
      if state[key] == buf then
        state[key] = nil
      end
    end,
  })
end

local function style(win)
  -- hide_numbers, and a bare gutter to match toggleterm's on_open.
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = 'no'
  vim.wo[win].spell = false

  -- A rule across the top of the terminal: the buffer's inactive statusline above it is
  -- too faint to read as a border. '%=' pads the winbar with the 'wbr' fillchar, so the
  -- line tracks the window width. Local scope only, or splits made from the terminal
  -- would inherit it. pcall: winbar needs Neovim 0.8+.
  pcall(function()
    local fc = vim.o.fillchars
    fc = (fc == '' and '' or fc .. ',') .. 'wbr:─'
    vim.api.nvim_set_option_value('fillchars', fc, { scope = 'local', win = win })
    vim.api.nvim_set_option_value('winbar', '%#TermSeparator#%=', { scope = 'local', win = win })
  end)
end

---Show the second shell to the right of `main_win`, starting it if needed.
local function open_second(main_win)
  local win = win_of(state.buf2)
  if win then
    return win
  end
  vim.api.nvim_set_current_win(main_win)
  vim.cmd 'rightbelow vsplit'
  win = vim.api.nvim_get_current_win()
  if valid(state.buf2) then
    vim.api.nvim_win_set_buf(win, state.buf2)
  else
    new_term 'buf2'
  end
  style(win)
  return win
end

local function open()
  vim.cmd('botright ' .. HEIGHT .. 'split')
  local win = vim.api.nvim_get_current_win()

  if buf_valid() then
    vim.api.nvim_win_set_buf(win, state.buf)
  else
    new_term 'buf'
  end
  style(win)

  -- The second shell toggles with the first, so bring it back if it is still alive.
  if valid(state.buf2) then
    open_second(win)
    vim.api.nvim_set_current_win(win)
  end

  if state.mode == 'i' then
    vim.cmd 'startinsert'
  end
end

local function close(win)
  -- Record the mode before hiding, so reopening lands you back where you were.
  state.mode = vim.fn.mode():sub(1, 1) == 't' and 'i' or 'n'
  local win2 = win_of(state.buf2)
  if win2 then
    vim.api.nvim_win_hide(win2)
  end
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

---Open a second, independent shell beside the terminal (opening that too if hidden),
---or jump to it if it is already showing.
local function split()
  local win = find_win()
  if not win then
    open()
    win = find_win()
  end
  vim.api.nvim_set_current_win(open_second(win))
  vim.cmd 'startinsert'
end

vim.keymap.set({ 'n', 't' }, '<leader>tt', toggle, { desc = '[T]oggle [T]erminal' })
vim.keymap.set({ 'n', 't' }, '<leader>tv', split, { desc = '[T]erminal: [V]ertical split, second shell' })
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

---Send buffer lines [first, last] to the terminal, one submitted line each. A multi-line
---send gets an extra blank line so a Python REPL closes any open indented block.
local function send_lines(first, last)
  local lines = vim.api.nvim_buf_get_lines(0, first - 1, last, false)
  if #lines == 0 then
    return
  end
  local text = table.concat(lines, '\r')
  if #lines > 1 then
    text = text .. '\r'
  end
  run(text)
end

vim.keymap.set('n', '<leader>ts', function()
  local count = vim.v.count1
  local first = vim.fn.line '.'
  send_lines(first, math.min(first + count - 1, vim.fn.line '$'))
end, { desc = '[T]erminal: [S]end line(s)' })
vim.keymap.set('x', '<leader>ts', function()
  local a, b = vim.fn.line 'v', vim.fn.line '.'
  vim.api.nvim_feedkeys(vim.keycode '<Esc>', 'nx', false)
  send_lines(math.min(a, b), math.max(a, b))
end, { desc = '[T]erminal: [S]end selection' })

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
