-- A Python REPL in a vertical split, no plugins. The parts of iron.nvim actually used.
--
-- Starts IPython from the active environment ($VIRTUAL_ENV, then $CONDA_PREFIX, then
-- PATH), so it sees the project's packages. If IPython is not installed there, it falls
-- back to the plain python console.
--
-- IPython brings its own syntax highlighting as you type, Tab completion (jedi, a menu
-- you move through with Tab / arrows) and suggestions from history (grey text after the
-- cursor; <Right> accepts it). The plain console only has Tab completion (readline), and
-- runs as the basic REPL (PYTHON_BASIC_REPL=1): Python 3.13's new REPL auto-indents, which
-- would double the indentation of everything sent to it.
--
--   <leader>rr  toggle the REPL (starts it the first time; the cursor stays put)
--   <leader>rF  focus the REPL, in insert mode     <leader>rh  hide it
--   <leader>rR  restart it
--
--   <leader>sc  send a motion (<leader>sc ip, <leader>sc iw) or, in visual mode, the selection
--   <leader>sl  send the line ([count] lines)      <leader>sp  send the paragraph
--   <leader>su  send line 1 through the cursor's line
--   <leader>sa  send the whole file
--   <leader>s<CR>     send <CR>                    <leader>s<Space>  interrupt (<C-c>)
--   <leader>sq  exit the REPL                      <leader>cl        clear the screen
--
-- Moved from the iron.nvim layout because this config already uses them: send file
-- (<leader>sff is the picker) and focus (<leader>rf is rename-file).
--
-- IPython gets code as one bracketed paste, so blank lines inside a function are fine.
-- The plain console reads line by line: blank lines are dropped and one is added where a
-- block ends, so blank lines inside a triple-quoted string are lost there.

local M = {}

local WIDTH = 0.619 -- fraction of the screen, as in the iron.nvim config
local READY_TIMEOUT = 20000 -- ms to wait for the first prompt before sending anyway

local is_win = vim.fn.has 'win32' == 1

local state = {
  buf = nil,
  chan = nil,
  kind = nil, -- 'ipython' or 'python'
  ready = false, -- the first prompt has appeared
  pending = {}, -- text sent before it did
}

---The environment's interpreter, the same search as notebook.lua.
local function python()
  for _, root in ipairs { vim.env.VIRTUAL_ENV, vim.env.CONDA_PREFIX } do
    if root and root ~= '' then
      local candidates = is_win and { root .. '/Scripts/python.exe', root .. '/python.exe' }
        or { root .. '/bin/python', root .. '/bin/python3' }
      for _, p in ipairs(candidates) do
        if vim.fn.executable(p) == 1 then
          return vim.fs.normalize(p)
        end
      end
    end
  end
  for _, name in ipairs(is_win and { 'python', 'python3' } or { 'python3', 'python' }) do
    local p = vim.fn.exepath(name)
    if p ~= '' then
      return p
    end
  end
  return nil
end

---True if `py` can import IPython. find_spec looks without importing, so this is quick.
local function has_ipython(py)
  local check = 'import importlib.util, sys; sys.exit(importlib.util.find_spec("IPython") is None)'
  local ok, res = pcall(function()
    return vim.system({ py, '-c', check }):wait()
  end)
  return ok and res.code == 0
end

local function running()
  return state.buf ~= nil and vim.api.nvim_buf_is_valid(state.buf)
end

---The window in this tab displaying the REPL, or nil.
local function find_win()
  if not running() then
    return nil
  end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(win) == state.buf then
      return win
    end
  end
  return nil
end

local function flush()
  state.ready = true
  for _, text in ipairs(state.pending) do
    vim.api.nvim_chan_send(state.chan, text)
  end
  state.pending = {}
end

---Poll the terminal for the first prompt. Text sent before it would be echoed by the
---tty as raw escape codes while IPython is still loading.
local function wait_ready(buf, elapsed)
  if state.buf ~= buf or state.ready then
    return
  end
  local prompt = state.kind == 'ipython' and '^In %[%d+%]:' or '^>>> '
  for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    if line:match(prompt) then
      return flush()
    end
  end
  if elapsed >= READY_TIMEOUT then
    return flush()
  end
  vim.defer_fn(function()
    wait_ready(buf, elapsed + 100)
  end, 100)
end

---Start the REPL in `win`.
local function start(win)
  local py = python()
  if not py then
    vim.notify('repl: no python found', vim.log.levels.ERROR)
    return
  end
  local cmd, env
  if has_ipython(py) then
    state.kind = 'ipython'
    cmd = { py, '-m', 'IPython', '--no-autoindent', '--no-confirm-exit', '--TerminalInteractiveShell.true_color=True' }
  else
    state.kind = 'python'
    cmd = { py }
    env = { PYTHON_BASIC_REPL = '1' }
  end

  local buf = vim.api.nvim_create_buf(false, false)
  vim.api.nvim_win_set_buf(win, buf)
  local chan
  vim.api.nvim_win_call(win, function()
    chan = vim.fn.jobstart(cmd, { term = true, env = env })
  end)
  if chan <= 0 then
    vim.notify('repl: could not start ' .. table.concat(cmd, ' '), vim.log.levels.ERROR)
    return
  end
  state.buf, state.chan, state.ready, state.pending = buf, chan, false, {}

  -- When the REPL exits, drop its buffer (and with it the window) so the next toggle
  -- starts a fresh one.
  vim.api.nvim_create_autocmd('TermClose', {
    buffer = buf,
    once = true,
    callback = function()
      if state.buf == buf then
        state.buf, state.chan = nil, nil
      end
      vim.schedule(function()
        if vim.api.nvim_buf_is_valid(buf) then
          vim.api.nvim_buf_delete(buf, { force = true })
        end
      end)
    end,
  })
  wait_ready(buf, 0)
end

---Show the REPL, starting it if needed. Returns its window; the cursor does not move.
local function open()
  local win = find_win()
  if win then
    return win
  end
  local from = vim.api.nvim_get_current_win()
  vim.cmd('botright ' .. math.floor(vim.o.columns * WIDTH) .. 'vsplit')
  win = vim.api.nvim_get_current_win()
  if running() then
    vim.api.nvim_win_set_buf(win, state.buf)
  else
    start(win)
  end
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = 'no'
  vim.wo[win].spell = false
  if vim.api.nvim_win_is_valid(from) then
    vim.api.nvim_set_current_win(from)
  end
  return win
end

function M.hide()
  local win = find_win()
  if win then
    vim.api.nvim_win_hide(win)
  end
end

function M.toggle()
  if find_win() then
    M.hide()
  else
    open()
  end
end

function M.focus()
  vim.api.nvim_set_current_win(open())
  vim.cmd 'startinsert'
end

function M.restart()
  local win = find_win()
  if running() then
    local buf = state.buf
    state.buf, state.chan = nil, nil
    pcall(vim.fn.jobstop, vim.bo[buf].channel)
    if win then
      -- Swap in a placeholder first, so deleting the old buffer keeps the window.
      vim.api.nvim_win_set_buf(win, vim.api.nvim_create_buf(false, true))
    end
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end
  if win then
    local placeholder = vim.api.nvim_win_get_buf(win)
    start(win)
    pcall(vim.api.nvim_buf_delete, placeholder, { force = true })
  else
    open()
  end
end

---Send raw text (keys) to a running REPL, showing it if hidden.
local function send_raw(text)
  if not running() then
    return
  end
  local win = open()
  -- Keep the REPL scrolled to the bottom, so it follows the output.
  if win then
    vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(state.buf), 0 })
  end
  if state.ready then
    vim.api.nvim_chan_send(state.chan, text)
  else
    table.insert(state.pending, text)
  end
end

---Strip the indentation every non-blank line shares, so an indented block can be sent.
local function dedent(lines)
  local min
  for _, line in ipairs(lines) do
    if line:match '%S' then
      local n = #line:match '^%s*'
      min = (min == nil or n < min) and n or min
    end
  end
  if not min or min == 0 then
    return lines
  end
  local out = {}
  for i, line in ipairs(lines) do
    out[i] = line:sub(min + 1)
  end
  return out
end

-- A top-level line starting with one of these continues the block above it.
local CONTINUES = { ['elif'] = true, ['else'] = true, ['except'] = true, ['finally'] = true }

local function continues_block(line)
  return CONTINUES[line:match '^(%a+)' or ''] or line:match '^[%)%]}]' ~= nil
end

---Keys for the plain console: one line at a time. Blank and comment-only lines are
---dropped (a blank line ends a block there); a blank line is added where a block ends.
local function for_python(lines)
  local out, indented = {}, false
  for _, line in ipairs(lines) do
    if line:match '%S' and not line:match '^%s*#' then
      local starts_indented = line:match '^%s' ~= nil
      if indented and not starts_indented and not continues_block(line) then
        table.insert(out, '')
      end
      table.insert(out, line)
      indented = starts_indented
    end
  end
  if indented then
    table.insert(out, '')
  end
  return #out > 0 and table.concat(out, '\r') .. '\r' or nil
end

---Keys for IPython: the code as one bracketed paste, then <CR> to run it. If it ends
---inside a block, the first <CR> only opens a new line, so a second one runs it.
local function for_ipython(lines)
  while #lines > 0 and not lines[#lines]:match '%S' do
    table.remove(lines)
  end
  if #lines == 0 then
    return nil
  end
  local text = '\27[200~' .. table.concat(lines, '\n') .. '\27[201~\r'
  if lines[#lines]:match '^%s' then
    text = text .. '\r'
  end
  return text
end

---Send lines of code. The REPL kind is only known once it has started, so start it first.
function M.send(lines)
  if not lines or #lines == 0 then
    return
  end
  if not running() then
    open()
    if not running() then
      return
    end
  end
  lines = dedent(lines)
  local text = state.kind == 'ipython' and for_ipython(lines) or for_python(lines)
  if text then
    send_raw(text)
  end
end

local function send_range(first, last)
  M.send(vim.api.nvim_buf_get_lines(0, first - 1, last, false))
end

---'operatorfunc' for <leader>sc: send the text the motion covered.
function M.operator(kind)
  local type = ({ line = 'V', char = 'v', block = '\22' })[kind] or 'v'
  M.send(vim.fn.getregion(vim.fn.getpos "'[", vim.fn.getpos "']", { type = type }))
end

local function send_visual()
  local lines = vim.fn.getregion(vim.fn.getpos 'v', vim.fn.getpos '.', { type = vim.fn.mode() })
  vim.api.nvim_feedkeys(vim.keycode '<Esc>', 'nx', false)
  M.send(lines)
end

---The paragraph around the cursor: the non-blank lines between blank ones.
local function send_paragraph()
  local first, last = vim.fn.line '.', vim.fn.line '.'
  local blank = function(n)
    return not vim.fn.getline(n):match '%S'
  end
  if blank(first) then
    return
  end
  while first > 1 and not blank(first - 1) do
    first = first - 1
  end
  while last < vim.fn.line '$' and not blank(last + 1) do
    last = last + 1
  end
  send_range(first, last)
end

local function map(mode, lhs, fn, desc, opts)
  vim.keymap.set(mode, lhs, fn, vim.tbl_extend('force', { desc = 'REPL: ' .. desc }, opts or {}))
end

map('n', '<leader>rr', M.toggle, 'toggle')
map('n', '<leader>rF', M.focus, 'focus')
map('n', '<leader>rh', M.hide, 'hide')
map('n', '<leader>rR', M.restart, 'restart')

map('n', '<leader>sc', function()
  vim.o.operatorfunc = "v:lua.require'core.repl'.operator"
  return 'g@'
end, 'send motion', { expr = true })
map('x', '<leader>sc', send_visual, 'send selection')
map('n', '<leader>sl', function()
  local first = vim.fn.line '.'
  send_range(first, math.min(first + vim.v.count1 - 1, vim.fn.line '$'))
end, 'send line')
map('n', '<leader>sp', send_paragraph, 'send paragraph')
map('n', '<leader>su', function()
  send_range(1, vim.fn.line '.')
end, 'send up to the cursor')
map('n', '<leader>sa', function()
  send_range(1, vim.fn.line '$')
end, 'send file')

map('n', '<leader>s<CR>', function()
  send_raw '\r'
end, 'send <CR>')
map('n', '<leader>s<Space>', function()
  send_raw '\3'
end, 'interrupt')
map('n', '<leader>sq', function()
  send_raw 'exit()\r'
end, 'exit')
map('n', '<leader>cl', function()
  send_raw '\12'
end, 'clear')

vim.api.nvim_create_user_command('Repl', M.toggle, { desc = 'Toggle the Python REPL' })

return M
