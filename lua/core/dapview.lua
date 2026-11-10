-- The debug panel for core.dap, modelled on nvim-dap-view: one split along the bottom
-- whose winbar switches sections, with the program's terminal to its right.
--
--   REPL [R]  Breakpoints [B]  Watches [W]  Scopes [S]  Exceptions [e]  Threads [T]
--
-- While the program starts or runs, the panel's bar animates with the seconds so far,
-- so a long run is easy to tell from a hang.
--
-- In the panel: <CR>/<Tab> expand a variable, jump to a breakpoint or frame, or flip an
-- exception filter. a/c/d add/change/delete a watch, d deletes a breakpoint, s sets a
-- variable, y yanks a value, q closes. In the REPL, <Up>/<Down> walk the history.

local dap = require 'core.dap'
local prompt = require 'lib.prompt'
local spinner = require 'lib.spinner'

local M = {}

local ns = vim.api.nvim_create_namespace 'core-dapview'
local PROMPT = '> '
local WARN = vim.log.levels.WARN

local SECTIONS = {
  { id = 'repl', key = 'R', label = 'REPL' },
  { id = 'breakpoints', key = 'B', label = 'Breakpoints' },
  { id = 'watches', key = 'W', label = 'Watches' },
  { id = 'scopes', key = 'S', label = 'Scopes' },
  { id = 'exceptions', key = 'e', label = 'Exceptions' },
  { id = 'threads', key = 'T', label = 'Threads' },
}

local V = {
  section = 'repl',
  win = nil, -- the panel
  view = nil, -- buffer the non-REPL sections render into
  repl = nil, -- prompt buffer
  term_win = nil,
  term_buf = nil,
  nodes = {}, -- panel line -> node under it
  scopes = {}, -- root nodes of the Scopes tree
  watches = {}, -- { expr, node }
  expanded = { Locals = true }, -- by node key, so expansions survive a step
  hover = nil, -- { win, buf, root, nodes }
  history = {},
  hist_i = nil,
}

local function valid_win(w)
  return w and vim.api.nvim_win_is_valid(w)
end
local function valid_buf(b)
  return b and vim.api.nvim_buf_is_valid(b)
end

local redraw -- defined below; everything async ends by calling it

-- ---------------------------------------------------------------------------
-- Variable trees. A node is { key, name, value?, type?, ref, children?, parent_ref? };
-- `ref` is the DAP variablesReference, > 0 when the value has children.
-- ---------------------------------------------------------------------------

local function short(v)
  v = tostring(v or ''):gsub('\r', ''):gsub('\n', '\\n')
  return #v > 300 and v:sub(1, 300) .. '...' or v
end

local function fetch(node)
  if node.ref == 0 or node.children or node.loading or not dap.session then
    return
  end
  node.loading = true
  dap.variables(node.ref, function(err, vars)
    node.loading = false
    node.children = {}
    if err then
      node.children[1] = { key = node.key .. '!', name = 'error', value = err, ref = 0, error = true }
    end
    for _, v in ipairs(vars) do
      local child = {
        key = node.key .. '.' .. v.name,
        name = v.name,
        value = v.value,
        type = v.type,
        ref = v.variablesReference or 0,
        parent_ref = node.ref,
      }
      node.children[#node.children + 1] = child
      if V.expanded[child.key] then
        fetch(child)
      end
    end
    redraw()
  end)
end

local function toggle_node(node)
  if not node or (node.ref or 0) == 0 then
    return
  end
  V.expanded[node.key] = not V.expanded[node.key] or nil
  if V.expanded[node.key] then
    fetch(node)
  end
  redraw()
end

-- Rendering collects lines, highlights and the node behind each line, then flushes.
local function builder()
  return { lines = {}, hls = {}, nodes = {} }
end

---chunks: { { text, hl_group? }, ... }
local function add(b, chunks, node)
  local line = ''
  for _, c in ipairs(chunks) do
    if c[2] and c[1] ~= '' then
      b.hls[#b.hls + 1] = { #b.lines, #line, #line + #c[1], c[2] }
    end
    line = line .. c[1]
  end
  b.lines[#b.lines + 1] = line
  b.nodes[#b.lines] = node
end

local function flush(buf, b)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, b.lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, h in ipairs(b.hls) do
    vim.api.nvim_buf_set_extmark(buf, ns, h[1], h[2], { end_col = h[3], hl_group = h[4] })
  end
end

local function add_tree(b, node, depth)
  local open = V.expanded[node.key]
  local indent = string.rep('  ', depth)
  local chunks = {
    { indent .. (node.ref > 0 and (open and '\u{25BE} ' or '\u{25B8} ') or '  ') },
    { node.name, node.scope and 'Title' or 'Identifier' },
  }
  if node.type and node.type ~= '' then
    chunks[#chunks + 1] = { ': ' }
    chunks[#chunks + 1] = { node.type, 'Type' }
  end
  if node.value and node.value ~= '' then
    chunks[#chunks + 1] = { ' = ' }
    chunks[#chunks + 1] = { short(node.value), node.error and 'ErrorMsg' or nil }
  end
  add(b, chunks, node)
  if open and node.ref > 0 then
    if node.children then
      for _, c in ipairs(node.children) do
        add_tree(b, c, depth + 1)
      end
    else
      add(b, { { indent .. '    loading...', 'Comment' } })
    end
  end
end

-- ---------------------------------------------------------------------------
-- Sections
-- ---------------------------------------------------------------------------

local function note(b, text)
  add(b, { { text, 'Comment' } })
end

local function not_stopped(b)
  local s = dap.session
  if not s then
    note(b, 'No debug session. <leader>ds debugs the current file.')
  elseif not s.launched and not s.stopped then
    note(b, ('Starting debugpy... %ds'):format(spinner.secs(s.since)))
  elseif not s.stopped then
    note(b, ('Running for %ds (:DapPause to break in)'):format(spinner.secs(s.since)))
  else
    return false
  end
  return true
end

local function source_line(path, line)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.fs.normalize(vim.api.nvim_buf_get_name(buf)) == path then
      return vim.api.nvim_buf_get_lines(buf, line - 1, line, false)[1] or ''
    end
  end
  local ok, lines = pcall(vim.fn.readfile, path, '', line)
  return ok and lines[line] or ''
end

local render = {}

render.scopes = function(b)
  if not_stopped(b) then
    return
  end
  if #V.scopes == 0 then
    note(b, 'loading...')
  end
  for _, n in ipairs(V.scopes) do
    add_tree(b, n, 0)
  end
end

render.watches = function(b)
  if #V.watches == 0 then
    return note(b, 'No watches. a adds one here, <leader>dw from your code.')
  end
  for _, w in ipairs(V.watches) do
    add_tree(b, w.node, 0)
  end
end

render.breakpoints = function(b)
  local list = dap.breakpoints()
  if #list == 0 then
    return note(b, 'No breakpoints. <leader>b sets one on the cursor line.')
  end
  for _, bp in ipairs(list) do
    local chunks = {
      { vim.fn.fnamemodify(bp.path, ':.'), 'Directory' },
      { ':' },
      { tostring(bp.line), 'LineNr' },
    }
    if bp.condition then
      chunks[#chunks + 1] = { '  if ' .. bp.condition, 'DiagnosticWarn' }
    end
    if bp.logMessage then
      chunks[#chunks + 1] = { '  log ' .. bp.logMessage, 'DiagnosticInfo' }
    end
    if bp.verified == false then
      chunks[#chunks + 1] = { '  (rejected)', 'DiagnosticHint' }
    end
    chunks[#chunks + 1] = { '  ' .. vim.trim(source_line(bp.path, bp.line)) }
    add(b, chunks, { bp = bp })
  end
end

render.exceptions = function(b)
  for _, f in ipairs(dap.exception_filters) do
    local on = dap.exceptions_on[f.filter]
    local auto = not on and f.filter == 'userUnhandled' and dap.session and dap.session.opts.test
    add(b, {
      { (on or auto) and '[x] ' or '[ ] ', (on or auto) and 'DiagnosticOk' or 'Comment' },
      { f.label },
      { auto and '  (always on while debugging tests)' or '', 'Comment' },
    }, { filter = f.filter })
  end
end

render.threads = function(b)
  if not_stopped(b) then
    return
  end
  local s = dap.session
  local threads = #s.threads > 0 and s.threads or { { id = s.thread_id, name = 'thread ' .. tostring(s.thread_id) } }
  for _, t in ipairs(threads) do
    local here = t.id == s.thread_id
    add(b, { { t.name, here and 'Title' or nil }, { here and ('  stopped: ' .. (s.reason or '')) or '', 'Comment' } })
    if here then
      for _, f in ipairs(s.frames) do
        local current = s.frame and f.id == s.frame.id
        local path = f.source and f.source.path
        local loc = path and (vim.fn.fnamemodify(path, ':.') .. ':' .. f.line) or '<no source>'
        add(b, {
          { current and '  > ' or '    ', 'DiagnosticWarn' },
          { f.name, current and 'Function' or nil },
          { '  ' .. loc, 'Comment' },
        }, { frame = f })
      end
    end
  end
end

-- ---------------------------------------------------------------------------
-- REPL: a prompt buffer; what you type is evaluated in the selected frame.
-- ---------------------------------------------------------------------------

local function repl_append(text, hl)
  local b = V.repl
  if not valid_buf(b) then
    return
  end
  local lines = vim.split((tostring(text):gsub('\r', ''):gsub('\n$', '')), '\n', { plain = true })
  -- The prompt is the last line; output goes above it.
  local at = vim.api.nvim_buf_line_count(b) - 1
  vim.api.nvim_buf_set_lines(b, at, at, false, lines)
  if hl then
    for i, l in ipairs(lines) do
      if l ~= '' then
        vim.api.nvim_buf_set_extmark(b, ns, at + i - 1, 0, { end_col = #l, hl_group = hl })
      end
    end
  end
  local last = vim.api.nvim_buf_line_count(b)
  for _, w in ipairs(vim.fn.win_findbuf(b)) do
    if w ~= vim.api.nvim_get_current_win() then
      vim.api.nvim_win_set_cursor(w, { last, 0 })
    end
  end
end

local function evaluate_in_repl(text)
  dap.evaluate(text, 'repl', function(err, body)
    if err then
      repl_append(err, 'ErrorMsg')
    elseif body.result and body.result ~= '' then
      repl_append(body.result)
    end
  end)
end

local function walk_history(delta)
  if #V.history == 0 then
    return
  end
  V.hist_i = math.max(1, math.min(#V.history + 1, (V.hist_i or #V.history + 1) + delta))
  local text = V.history[V.hist_i] or ''
  local last = vim.api.nvim_buf_line_count(V.repl)
  vim.api.nvim_buf_set_lines(V.repl, last - 1, last, false, { PROMPT .. text })
  vim.api.nvim_win_set_cursor(0, { last, #PROMPT + #text })
end

local section_keys -- defined with the window code

local function repl_buf()
  if valid_buf(V.repl) then
    return V.repl
  end
  local b = vim.api.nvim_create_buf(false, true)
  V.repl = b
  vim.bo[b].buftype = 'prompt'
  vim.bo[b].bufhidden = 'hide'
  vim.bo[b].filetype = 'dap-repl'
  vim.fn.prompt_setprompt(b, PROMPT)
  vim.fn.prompt_setcallback(b, function(text)
    if text == '' then
      return
    end
    if V.history[#V.history] ~= text then
      V.history[#V.history + 1] = text
    end
    V.hist_i = nil
    -- Neovim appends the next prompt after this callback returns; output must follow it.
    vim.schedule(function()
      evaluate_in_repl(text)
    end)
  end)
  vim.keymap.set('i', '<Up>', function()
    walk_history(-1)
  end, { buffer = b })
  vim.keymap.set('i', '<Down>', function()
    walk_history(1)
  end, { buffer = b })
  section_keys(b)
  return b
end

-- ---------------------------------------------------------------------------
-- Windows
-- ---------------------------------------------------------------------------

local function style(win)
  local wo = vim.wo[win]
  wo.number, wo.relativenumber, wo.signcolumn, wo.foldcolumn = false, false, 'no', '0'
  wo.wrap, wo.spell, wo.list = false, false, false
  wo.winfixheight = true
end

local function winbar()
  local parts = {}
  for _, sec in ipairs(SECTIONS) do
    local hl = sec.id == V.section and '%#TabLineSel#' or '%#TabLine#'
    parts[#parts + 1] = ('%s %s [%s] '):format(hl, sec.label, sec.key)
  end
  local s = dap.session
  -- Starting / running goes first, animated: the bar is often too narrow for its end.
  local busy = ''
  if s and not s.stopped then
    busy = '%#Comment# ' .. spinner.label(s.since, s.launched and 'running' or 'starting debugpy') .. ' '
  end
  local state = not s and 'no session' or s.stopped and ('stopped: ' .. (s.reason or '?')) or ''
  return busy
    .. table.concat(parts)
    .. '%#TabLineFill#%<%=%#Comment# '
    .. state:gsub('%%', '%%%%')
    .. '  <leader>d + c continue  n next  i into  o out  q quit '
end

local function open_term_win()
  V.term_win = vim.api.nvim_open_win(V.term_buf, false, {
    split = 'right',
    win = V.win,
    width = math.floor(vim.api.nvim_win_get_width(V.win) / 2),
  })
  style(V.term_win)
end

local view_buf -- defined below, needs the node actions

function M.open()
  if valid_win(V.win) then
    return V.win
  end
  local buf = V.section == 'repl' and repl_buf() or view_buf()
  V.win = vim.api.nvim_open_win(buf, false, {
    split = 'below',
    win = -1, -- full width, along the bottom
    height = math.max(10, math.floor(vim.o.lines * 0.25)),
  })
  style(V.win)
  if valid_buf(V.term_buf) and not valid_win(V.term_win) then
    open_term_win()
  end
  redraw()
  return V.win
end

function M.close()
  for _, w in ipairs { V.term_win, V.win } do
    if valid_win(w) then
      pcall(vim.api.nvim_win_close, w, false)
    end
  end
end

function M.toggle()
  if valid_win(V.win) then
    M.close()
  else
    M.open()
  end
end

function M.show(id)
  V.section = id
  M.open()
  vim.api.nvim_win_set_buf(V.win, id == 'repl' and repl_buf() or view_buf())
  style(V.win)
  redraw()
end

---Called by core.dap for runInTerminal. Returns the window the job should start in.
function M.show_terminal(buf)
  M.open()
  local old = V.term_buf
  V.term_buf = buf
  if valid_win(V.term_win) then
    vim.api.nvim_win_set_buf(V.term_win, buf)
  else
    open_term_win()
  end
  if valid_buf(old) and old ~= buf then
    pcall(vim.api.nvim_buf_delete, old, { force = true })
  end
  return V.term_win
end

section_keys = function(buf)
  for _, sec in ipairs(SECTIONS) do
    vim.keymap.set('n', sec.key, function()
      M.show(sec.id)
    end, { buffer = buf, nowait = true, desc = 'Debug panel: ' .. sec.label })
  end
  vim.keymap.set('n', 'q', M.close, { buffer = buf, nowait = true })
end

---Focus an ordinary window (preferring the previous one) and open path:line in it.
local function goto_location(path, line)
  local function ok(w)
    return valid_win(w)
      and w ~= V.win
      and w ~= V.term_win
      and vim.api.nvim_win_get_config(w).relative == ''
      and vim.bo[vim.api.nvim_win_get_buf(w)].buftype == ''
  end
  local target = vim.fn.win_getid(vim.fn.winnr '#')
  if not ok(target) then
    target = nil
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if ok(w) then
        target = w
        break
      end
    end
  end
  if not target then
    return
  end
  vim.api.nvim_set_current_win(target)
  vim.cmd.edit(vim.fn.fnameescape(path))
  pcall(vim.api.nvim_win_set_cursor, target, { line, 0 })
  vim.cmd 'normal! zz'
end

-- ---------------------------------------------------------------------------
-- Watches
-- ---------------------------------------------------------------------------

local function eval_watch(w)
  w.node = { key = 'watch:' .. w.expr, name = w.expr, ref = 0, watch = w }
  if not (dap.session and dap.session.stopped) then
    return
  end
  dap.evaluate(w.expr, 'watch', function(err, body)
    w.node = {
      key = 'watch:' .. w.expr,
      name = w.expr,
      value = err or body.result,
      type = not err and body.type or nil,
      ref = not err and body.variablesReference or 0,
      error = err ~= nil,
      watch = w,
    }
    if V.expanded[w.node.key] then
      fetch(w.node)
    end
    redraw()
  end)
end

---The visual selection as text, leaving visual mode. nil outside visual mode.
local function selection()
  local mode = vim.fn.mode()
  if not mode:match '[vV\22]' then
    return nil
  end
  local lines = vim.fn.getregion(vim.fn.getpos 'v', vim.fn.getpos '.', { type = mode })
  vim.api.nvim_feedkeys(vim.keycode '<Esc>', 'nx', false)
  return table.concat(lines, '\n')
end

function M.add_watch(expr)
  expr = expr or selection() or vim.fn.expand '<cexpr>'
  if not expr or vim.trim(expr) == '' then
    return
  end
  local w = { expr = vim.trim(expr) }
  V.watches[#V.watches + 1] = w
  eval_watch(w)
  M.show 'watches'
end

-- ---------------------------------------------------------------------------
-- Panel actions
-- ---------------------------------------------------------------------------

local function node_at_cursor()
  return V.nodes[vim.api.nvim_win_get_cursor(0)[1]]
end

local function activate(node)
  if not node then
    return
  elseif node.filter then
    dap.toggle_exception(node.filter)
  elseif node.frame then
    dap.select_frame(node.frame)
  elseif node.bp then
    goto_location(node.bp.path, node.bp.line)
  else
    toggle_node(node)
  end
end

local function delete(node)
  if node and node.watch then
    V.watches = vim.tbl_filter(function(w)
      return w ~= node.watch
    end, V.watches)
    redraw()
  elseif node and node.bp then
    dap.remove_breakpoint(node.bp.path, node.bp.line)
  end
end

local function change_watch(node)
  local w = node and node.watch
  if not w then
    return
  end
  local n = w.node or {}
  prompt.input({
    title = 'Change watch',
    info = { 'Watch      ' .. w.expr, 'Value      ' .. tostring(n.value or '(not evaluated: not stopped)') },
    box_title = 'new expression',
    default = w.expr,
    on_submit = function(expr)
      w.expr = expr
      eval_watch(w)
      redraw()
    end,
  })
end

local function set_value(node)
  if not node or not node.parent_ref then
    return
  end
  local value = tostring(node.value or '')
  prompt.input({
    title = 'Set variable',
    info = {
      'Variable   ' .. node.name,
      'Type       ' .. (node.type or 'unknown'),
      'Current    ' .. (#value > 80 and value:sub(1, 77) .. '...' or value),
    },
    box_title = node.name .. ' = (a Python expression)',
    default = value,
    on_submit = function(value)
    dap.set_variable(node.parent_ref, node.name, value, function(err, body)
      if err then
        return vim.notify(err, WARN)
      end
      node.value, node.type = body.value, body.type or node.type
      node.ref, node.children = body.variablesReference or node.ref, nil
      for _, w in ipairs(V.watches) do
        eval_watch(w)
      end
      redraw()
    end)
    end,
  })
end

view_buf = function()
  if valid_buf(V.view) then
    return V.view
  end
  local b = vim.api.nvim_create_buf(false, true)
  V.view = b
  vim.bo[b].bufhidden = 'hide'
  vim.bo[b].filetype = 'dap-view'
  vim.bo[b].modifiable = false
  section_keys(b)
  local function map(lhs, fn)
    vim.keymap.set('n', lhs, function()
      fn(node_at_cursor())
    end, { buffer = b, nowait = true })
  end
  map('<CR>', activate)
  map('<Tab>', activate)
  map('d', delete)
  map('c', change_watch)
  map('s', set_value)
  map('a', function()
    prompt.input({
      title = 'Add watch',
      info = { 'An expression, evaluated in the selected frame at every stop.' },
      box_title = 'expression',
      on_submit = M.add_watch,
    })
  end)
  map('y', function(node)
    if node and node.value then
      vim.fn.setreg(vim.v.register, node.value)
    end
  end)
  return b
end

-- ---------------------------------------------------------------------------
-- Hover: evaluate the expression under the cursor (or the selection) in a float.
-- ---------------------------------------------------------------------------

local function close_hover()
  if V.hover and valid_win(V.hover.win) then
    pcall(vim.api.nvim_win_close, V.hover.win, true)
  end
  V.hover = nil
end

local function render_hover()
  local h = V.hover
  if not h or not valid_win(h.win) then
    return
  end
  local b = builder()
  add_tree(b, h.root, 0)
  flush(h.buf, b)
  h.nodes = b.nodes
  local width = math.max(20, vim.fn.strdisplaywidth(h.title) + 4, vim.fn.strdisplaywidth(h.footer) + 4)
  for _, l in ipairs(b.lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l) + 1)
  end
  vim.api.nvim_win_set_config(h.win, {
    width = math.min(width, math.floor(vim.o.columns * 0.8)),
    height = math.min(#b.lines, 20),
  })
end

function M.hover()
  if V.hover and valid_win(V.hover.win) then -- second press focuses it, like K
    return vim.api.nvim_set_current_win(V.hover.win)
  end
  local expr = selection() or vim.fn.expand '<cexpr>'
  if not expr or vim.trim(expr) == '' then
    return
  end
  local origin = vim.api.nvim_get_current_buf()
  dap.evaluate(expr, 'hover', function(err, body)
    if err then
      return vim.notify(err, WARN)
    end
    close_hover()
    local root = { key = 'hover:' .. expr, name = expr, value = body.result, type = body.type, ref = body.variablesReference or 0 }
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = 'wipe'
    local short = #expr > 40 and expr:sub(1, 37) .. '...' or expr
    local title = ' ' .. short .. (body.type and (' \u{00B7} ' .. body.type) or '') .. ' '
    local footer = (root.ref > 0 and ' <CR> expand ' or ' ') .. ' y yank  w watch  q close '
    local win = vim.api.nvim_open_win(buf, false, {
      relative = 'cursor',
      row = 1,
      col = 0,
      width = 20,
      height = 1,
      border = prompt.border(),
      style = 'minimal',
      title = title,
      title_pos = 'left',
      footer = footer,
      footer_pos = 'right',
    })
    vim.wo[win].winhighlight = prompt.winhighlight()
    V.hover = { win = win, buf = buf, root = root, nodes = {}, title = title, footer = footer }
    local function node()
      return V.hover and V.hover.nodes[vim.api.nvim_win_get_cursor(0)[1]]
    end
    for _, lhs in ipairs { '<CR>', '<Tab>' } do
      vim.keymap.set('n', lhs, function()
        toggle_node(node())
      end, { buffer = buf, nowait = true })
    end
    -- y: the value on this line into the register; w: watch the hovered expression.
    vim.keymap.set('n', 'y', function()
      local n = node()
      if n and n.value then
        vim.fn.setreg(vim.v.register, n.value)
        vim.notify('yanked ' .. n.name)
      end
    end, { buffer = buf, nowait = true })
    vim.keymap.set('n', 'w', function()
      M.add_watch(expr)
      close_hover()
      vim.notify('watching ' .. expr)
    end, { buffer = buf, nowait = true })
    for _, lhs in ipairs { 'q', '<Esc>' } do
      vim.keymap.set('n', lhs, close_hover, { buffer = buf, nowait = true })
    end
    vim.api.nvim_create_autocmd({ 'CursorMoved', 'InsertEnter' }, { buffer = origin, once = true, callback = close_hover })
    if root.ref > 0 then
      V.expanded[root.key] = true
      fetch(root)
    end
    render_hover()
  end)
end

---<leader>ss: echo the selection into the REPL and run it in the current frame.
function M.send_selection()
  local text = selection()
  if not text or vim.trim(text) == '' then
    return
  end
  repl_buf()
  M.show 'repl'
  for _, l in ipairs(vim.split(text, '\n', { plain = true })) do
    repl_append(PROMPT .. l, 'Comment')
  end
  evaluate_in_repl(text)
end

-- ---------------------------------------------------------------------------
-- Redraw, and reacting to core.dap
-- ---------------------------------------------------------------------------

local queued = false
redraw = function()
  if queued then
    return
  end
  queued = true
  vim.schedule(function()
    queued = false
    if valid_win(V.win) then
      vim.wo[V.win].winbar = winbar()
      if V.section ~= 'repl' then
        local b = builder()
        render[V.section](b)
        flush(view_buf(), b)
        V.nodes = b.nodes
      end
    end
    render_hover()
  end)
end

-- While a session is starting or running, animate the bar 8 times a second. The panel
-- itself (with its "Running for Ns" note) is rebuilt only when the seconds change.
local stop_tick, last_sec
local function sync_tick()
  local s = dap.session
  local busy = s and not s.stopped
  if busy and not stop_tick then
    stop_tick = spinner.tick(function()
      local cur = dap.session
      if not (cur and valid_win(V.win)) then
        return
      end
      local sec = spinner.secs(cur.since)
      if sec ~= last_sec then
        last_sec = sec
        redraw()
      else
        vim.wo[V.win].winbar = winbar()
      end
    end)
  elseif not busy and stop_tick then
    stop_tick()
    stop_tick, last_sec = nil, nil
  end
end

dap.on(function(event, data)
  if event == 'start' then
    repl_buf()
    M.open()
    repl_append(('--- debugging %s ---'):format(data.config.name or '?'), 'Comment')
  elseif event == 'scopes' then
    V.scopes = {}
    for _, sc in ipairs(dap.session.scopes or {}) do
      local n = { key = sc.name, name = sc.name, ref = sc.variablesReference or 0, scope = true }
      V.scopes[#V.scopes + 1] = n
      if V.expanded[n.key] and not sc.expensive then
        fetch(n)
      end
    end
  elseif event == 'frame' or event == 'continued' or event == 'end' then
    if event ~= 'frame' then
      V.scopes = {}
    end
    for _, w in ipairs(V.watches) do
      eval_watch(w)
    end
    if event == 'end' then
      repl_append('--- session ended ---', 'Comment')
    end
  elseif event == 'output' then
    local hl = data.category == 'stderr' and 'ErrorMsg' or data.category == 'console' and 'Comment' or nil
    repl_append(data.output or '', hl)
  elseif event == 'exception' then
    local msg = ('%s: %s'):format(data.exceptionId or 'exception', data.description or '')
    repl_append('stopped on ' .. msg, 'WarningMsg')
    vim.notify(msg, WARN)
  end
  sync_tick()
  redraw()
end)

return M
