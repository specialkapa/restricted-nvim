-- Dialogs in floating windows: an optional info box with the context, and under it either
-- a one-line input box or a yes/no question. Not loaded from init.lua: modules require it.
--
--   local prompt = require 'lib.prompt'
--   prompt.input({ title = 'Watch', info = { 'Current: x + 1' }, default = 'x + 1',
--                  on_submit = function(text) ... end })
--   prompt.confirm({ title = 'Delete query', info = { 'File  q.sql' }, danger = true,
--                    on_yes = function() ... end })                  -- y / n
--   prompt.confirm({ ..., type_to_confirm = 'orders', on_yes = ... }) -- type the name
--
-- info: a list of lines; a line can also be { text, highlight group }. Empty input or a
-- cancel (<Esc>, <C-c>, q in normal mode, or leaving the window) calls opts.on_cancel.
-- input's complete = 'file' makes <Tab> / <S-Tab> complete paths (<C-x><C-f>, relative to
-- the cwd). Callbacks run back in the window the dialog was opened from.
--
-- Look: vim.g.prompt_border = 'rounded' (default), 'bold' (heavy lines), 'double', 'single';
-- vim.g.prompt_border_hl = the highlight group whose colour the border takes ('Function').

local M = {}

local api = vim.api

---Colour `attr` of the first of `names` that defines it, following links.
local function color(names, attr)
  for _, name in ipairs(names) do
    local ok, hl = pcall(api.nvim_get_hl, 0, { name = name, link = false })
    if ok and hl[attr] then
      return hl[attr]
    end
  end
end

---The dialog's own groups: the theme's border / error / title / comment colours, all on
---the editor's Normal background -- many themes give FloatBorder and NormalFloat a darker
---background, which looks like a box behind the box. Redone on every open, so a
---:colorscheme change is picked up.
local function set_highlights()
  local bg = color({ 'Normal' }, 'bg')
  local set = function(name, fg_from, extra)
    local spec = vim.tbl_extend('force', { fg = color(fg_from, 'fg'), bg = bg }, extra or {})
    api.nvim_set_hl(0, name, spec)
  end
  set('LibPromptNormal', { 'Normal' })
  -- An accent, not FloatBorder: themes often keep that muted, and it disappears against
  -- Normal. The same choice as the notebook's active-cell box. vim.g.prompt_border_hl
  -- names another group to take the colour from.
  set('LibPromptBorder', { vim.g.prompt_border_hl or 'Function', 'Identifier', 'DiagnosticInfo', 'FloatBorder' })
  set('LibPromptDanger', { 'DiagnosticError', 'ErrorMsg' })
  set('LibPromptTitle', { 'Title', 'Normal' }, { bold = true })
  set('LibPromptFooter', { 'Comment' })
end

---The border style for dialogs and floats that share their look.
function M.border()
  return vim.g.prompt_border or 'rounded'
end

---'winhighlight' for any float that should look like these dialogs: border, title and
---footer in the theme's colours on its Normal background. `danger` makes them red.
function M.winhighlight(danger)
  set_highlights()
  local border, title = danger and 'LibPromptDanger' or 'LibPromptBorder', danger and 'LibPromptDanger' or 'LibPromptTitle'
  return ('NormalFloat:LibPromptNormal,FloatBorder:%s,FloatTitle:%s,FloatFooter:LibPromptFooter'):format(border, title)
end

---Show `opts.info` (if any) and, below it, a 1-line box when `box` is true. Returns the
---info window (or nil), the box window (or nil), and a function that closes both.
local function open(opts, box)
  local from = api.nvim_get_current_win()
  local lines, marks = {}, {}
  for i, l in ipairs(opts.info or {}) do
    local text, hl = l, nil
    if type(l) == 'table' then
      text, hl = l[1], l[2]
    end
    lines[i] = '  ' .. text .. '  '
    if hl then
      marks[#marks + 1] = { i - 1, hl }
    end
  end
  if #lines > 0 then
    table.insert(lines, 1, '')
    table.insert(lines, '')
    for _, m in ipairs(marks) do
      m[1] = m[1] + 1
    end
  end

  local title = ' ' .. (opts.title or '') .. ' '
  local width = math.max(50, vim.fn.strdisplaywidth(title) + 4, vim.fn.strdisplaywidth(opts.footer or '') + 4)
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end
  width = math.min(width, vim.o.columns - 4)
  local total = (#lines > 0 and #lines + 2 or 0) + (box and 3 or 0)
  local row = math.max(0, math.floor((vim.o.lines - total) / 2) - 1)
  local col = math.max(0, math.floor((vim.o.columns - width) / 2))
  local winhl = M.winhighlight(opts.danger)

  local iw
  if #lines > 0 then
    local b = api.nvim_create_buf(false, true)
    api.nvim_buf_set_lines(b, 0, -1, false, lines)
    local ns = api.nvim_create_namespace('lib.prompt')
    for _, m in ipairs(marks) do
      api.nvim_buf_set_extmark(b, ns, m[1], 0, { end_col = #lines[m[1] + 1], hl_group = m[2] })
    end
    vim.bo[b].modifiable, vim.bo[b].bufhidden = false, 'wipe'
    iw = api.nvim_open_win(b, not box, {
      relative = 'editor', row = row, col = col, width = width, height = #lines,
      style = 'minimal', border = M.border(), title = title, title_pos = 'center',
      footer = not box and opts.footer or nil, footer_pos = not box and opts.footer and 'right' or nil,
      focusable = not box, zindex = 60,
    })
    vim.wo[iw].winhighlight = winhl
    row = row + #lines + 2
  end

  local bw
  if box then
    local b = api.nvim_create_buf(false, true)
    vim.bo[b].bufhidden = 'wipe'
    bw = api.nvim_open_win(b, true, {
      relative = 'editor', row = row, col = col, width = width, height = 1,
      style = 'minimal', border = M.border(), zindex = 60,
      title = iw and (' ' .. (opts.box_title or '') .. ' ') or title, title_pos = 'left',
      footer = opts.footer, footer_pos = 'right',
    })
    vim.wo[bw].winhighlight = winhl
  end

  local closed = false
  local function close()
    if closed then
      return false
    end
    closed = true
    -- Not ipairs: a yes/no dialog has no box, and ipairs would stop at that nil.
    if bw then
      pcall(api.nvim_win_close, bw, true)
    end
    if iw then
      pcall(api.nvim_win_close, iw, true)
    end
    if api.nvim_win_is_valid(from) then
      api.nvim_set_current_win(from)
    end
    return true
  end
  return iw, bw, close
end

---Keymaps for a dialog window: <CR> runs `submit` (if given), <Esc> / <C-c> / q `cancel`.
---In insert mode the box is left first, so leaving it can't move the cursor elsewhere.
local function keys(win, submit, cancel)
  local buf = api.nvim_win_get_buf(win)
  local function from_insert(fn)
    return function()
      vim.schedule(fn)
      return '<Esc>'
    end
  end
  if submit then
    vim.keymap.set('i', '<CR>', from_insert(submit), { buffer = buf, expr = true })
    vim.keymap.set('n', '<CR>', submit, { buffer = buf, nowait = true })
  end
  for _, lhs in ipairs({ '<Esc>', '<C-c>' }) do
    vim.keymap.set('i', lhs, from_insert(cancel), { buffer = buf, expr = true })
    vim.keymap.set('n', lhs, cancel, { buffer = buf, nowait = true })
  end
  vim.keymap.set('n', 'q', cancel, { buffer = buf, nowait = true })
  api.nvim_create_autocmd('WinLeave', { buffer = buf, once = true, callback = cancel })
end

---A one-line input box, with the context above it.
---opts: title, info, box_title (the box's title when there is info), default, complete,
---footer, danger, on_submit(text), on_cancel().
function M.input(opts)
  opts.footer = opts.footer or (opts.complete and ' <Tab> complete  <CR> ok  <Esc> cancel ' or ' <CR> ok  <Esc> cancel ')
  local _, bw, close = open(opts, true)
  local buf = api.nvim_win_get_buf(bw)
  if opts.default and opts.default ~= '' then
    api.nvim_buf_set_lines(buf, 0, -1, false, { opts.default })
    api.nvim_win_set_cursor(bw, { 1, #opts.default })
  end
  local function cancel()
    if close() and opts.on_cancel then
      opts.on_cancel()
    end
  end
  local function submit()
    local text = vim.trim(api.nvim_buf_get_lines(buf, 0, 1, false)[1] or '')
    if not close() then
      return
    end
    if text == '' then
      return opts.on_cancel and opts.on_cancel()
    end
    opts.on_submit(text)
  end
  keys(bw, submit, cancel)
  if opts.complete then
    vim.keymap.set('i', '<Tab>', function()
      return vim.fn.pumvisible() == 1 and '<C-n>' or '<C-x><C-f>'
    end, { buffer = buf, expr = true })
    vim.keymap.set('i', '<S-Tab>', function()
      return vim.fn.pumvisible() == 1 and '<C-p>' or ''
    end, { buffer = buf, expr = true })
  end
  vim.cmd.startinsert({ bang = true })
end

---A question. With `type_to_confirm`, a box where that word must be typed; otherwise
---y / n on the info box. opts: title, info, danger, type_to_confirm, on_yes(), on_cancel().
function M.confirm(opts)
  local word = opts.type_to_confirm
  if word then
    return M.input({
      title = opts.title,
      info = opts.info,
      danger = opts.danger,
      box_title = ('type %s to confirm'):format(word),
      footer = ' <CR> confirm  <Esc> cancel ',
      on_cancel = opts.on_cancel,
      on_submit = function(text)
        if text == word then
          return opts.on_yes()
        end
        vim.notify(('cancelled: %q is not %q'):format(text, word), vim.log.levels.WARN)
        if opts.on_cancel then
          opts.on_cancel()
        end
      end,
    })
  end
  opts.footer = opts.footer or ' y yes  n no '
  opts.info = opts.info and #opts.info > 0 and opts.info or { opts.title or 'Are you sure?' }
  local iw, _, close = open(opts, false)
  local function cancel()
    if close() and opts.on_cancel then
      opts.on_cancel()
    end
  end
  local function yes()
    if close() then
      opts.on_yes()
    end
  end
  -- No <CR>: a yes must be a deliberate y, not an Enter pressed out of habit.
  keys(iw, nil, cancel)
  local buf = api.nvim_win_get_buf(iw)
  for _, lhs in ipairs({ 'y', 'Y' }) do
    vim.keymap.set('n', lhs, yes, { buffer = buf, nowait = true })
  end
  for _, lhs in ipairs({ 'n', 'N' }) do
    vim.keymap.set('n', lhs, cancel, { buffer = buf, nowait = true })
  end
end

return M
