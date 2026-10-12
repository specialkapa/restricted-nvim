-- Jupyter notebooks as plain Python, run by a real Jupyter kernel. No plugins.
--
-- Opening a .ipynb shows it as a percent-format script, the layout jupytext and VS Code
-- use, so ty, ruff and everything else that works on Python works here too:
--
--   # %%                 a code cell
--   # %% [markdown]      a markdown cell -- every line commented with '# '
--   # %% [raw]           a raw cell
--
-- :w turns it back into notebook JSON, keeping every cell's id, metadata and outputs,
-- formatted the way Jupyter writes it (indent 1, sorted keys) so diffs stay small.
-- :w other.py writes the script itself instead.
--
-- Cells run in a Jupyter kernel started from the active environment's python, through a
-- small helper (BRIDGE, at the bottom of this file) that speaks the Jupyter protocol via
-- jupyter_client. Needs jupyter_client and ipykernel in that environment -- nothing else.
-- One kernel per notebook, started on the first run, stopped when the buffer goes.
--
--   <leader>jx  run the cell under the cursor
--   <leader>jn  run it and move to the next cell (adds one at the end, like Jupyter)
--   <leader>ja  run all cells          <leader>jA  run all cells up to this one
--   <leader>ji  interrupt the kernel   <leader>jR  restart it
--   <leader>jo  the cell's full output in a split; <CR> on an image opens it externally
--   <leader>jc  clear the cell's output   <leader>jC  clear all output
--   <leader>jb  new code cell below    <leader>jm  new markdown cell below
--   ]j / [j     next / previous cell
--   zc / zo     fold / unfold a cell; zM folds them all into an outline, zR opens all
--
-- Pause after <leader>j and a legend of all of the above pops up (see M.legend).
--
-- Each cell is drawn as a box (see render), the one under the cursor in an accent colour.
--
--   :NotebookLog   the kernel process's own stdout/stderr. Spark's JVM logging and
--                  progress bars go there, not into the notebook -- same as Jupyter.
--   :NotebookStop  shut the kernel down

local M = {}

-- Output lines shown under a cell before it is cut short; <leader>jo shows the rest.
local MAX_LINES = 30

local ns_cells = vim.api.nvim_create_namespace('notebook-cells') -- one mark per cell header
local ns_out = vim.api.nvim_create_namespace('notebook-output') -- boxes and outputs

local HEADER = '^# %%%%'
local is_win = vim.fn.has('win32') == 1
local dict_mt = getmetatable(vim.empty_dict())

-- Per-buffer state:
--   meta    the notebook minus its cells (metadata, nbformat, nbformat_minor)
--   cells   cell data keyed by the extmark id on its header line. Extmarks follow edits,
--           so a cell keeps its outputs and id however much the text around it moves.
--   kernel  the running bridge, or nil
---@type table<integer, table>
local books = {}

-- ---------------------------------------------------------------------------
-- Small helpers

---First foreground colour defined among `names`, so the boxes follow the colorscheme.
local function fg_of(names)
  for _, name in ipairs(names) do
    local ok, t = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
    if ok and t.fg then
      return t.fg
    end
  end
end

local function hl()
  local set = function(name, spec)
    spec.default = true
    vim.api.nvim_set_hl(0, name, spec)
  end
  local link = function(name, to)
    set(name, { link = to })
  end
  -- Box lines in the muted comment colour; the cell under the cursor in an accent.
  set('NotebookBorder', { fg = fg_of({ 'Comment', 'NonText' }) })
  set('NotebookBorderActive', { fg = fg_of({ 'Function', 'Identifier', 'DiagnosticInfo' }) })
  set('NotebookLabel', { fg = fg_of({ 'Normal' }), bold = true })
  link('NotebookCellNumber', 'Comment')
  link('NotebookStatus', 'Comment')
  link('NotebookOutput', 'Normal')
  link('NotebookStderr', 'DiagnosticWarn')
  link('NotebookError', 'DiagnosticError')
end
hl()
vim.api.nvim_create_autocmd('ColorScheme', { callback = hl })

---nbformat stores multiline text as a string OR a list of lines; always hand back a string.
local function join(v)
  if type(v) == 'table' then
    return table.concat(v)
  end
  return type(v) == 'string' and v or ''
end

---Python's str.splitlines(keepends=True), which is how nbformat stores text on disk.
local function splitlines(s)
  local out = {}
  for piece in s:gmatch('[^\n]*\n?') do
    if piece ~= '' then
      out[#out + 1] = piece
    end
  end
  return out
end

local function strip_ansi(s)
  return (s:gsub('\27%[[%d;?]*%a', ''))
end

---Lines of `s` as a terminal would show them: a \r returns to the start of the line, so
---only the text after the last one survives. Without this, one Spark or tqdm progress
---bar is hundreds of lines.
local function display_lines(s)
  s = strip_ansi(s:gsub('\r\n', '\n'))
  local out = vim.split(s, '\n', { plain = true })
  if out[#out] == '' then
    out[#out] = nil
  end
  for i, line in ipairs(out) do
    out[i] = line:gsub('\r+$', ''):match('[^\r]*$')
  end
  return out
end

local function new_id()
  local ok, bytes = pcall(vim.uv.random, 4)
  if ok and bytes then
    return (bytes:gsub('.', function(c)
      return ('%02x'):format(c:byte())
    end))
  end
  return ('%08x'):format(vim.uv.hrtime() % 0x100000000)
end

local function header_type(line)
  local tag = line:match('^# %%%%%s*%[(%w+)%]')
  if tag == 'markdown' or tag == 'md' then
    return 'markdown'
  elseif tag == 'raw' then
    return 'raw'
  end
  return 'code'
end

local function header_for(type)
  return type == 'code' and '# %%' or ('# %%%% [%s]'):format(type)
end

-- ---------------------------------------------------------------------------
-- JSON out, byte-for-byte the way Jupyter writes it: json.dumps(nb, indent=1,
-- sort_keys=True, ensure_ascii=False) plus a trailing newline. vim.json.encode would
-- put the whole notebook on one line.

local function encode(v, level, out)
  if v == nil or v == vim.NIL then
    out[#out + 1] = 'null'
    return
  end
  if type(v) ~= 'table' then
    out[#out + 1] = vim.json.encode(v)
    return
  end
  local pad = '\n' .. (' '):rep(level + 1)
  if getmetatable(v) == dict_mt or (next(v) ~= nil and not vim.islist(v)) then
    local keys = vim.tbl_keys(v)
    if #keys == 0 then
      out[#out + 1] = '{}'
      return
    end
    table.sort(keys)
    out[#out + 1] = '{'
    for i, k in ipairs(keys) do
      out[#out + 1] = (i > 1 and ',' or '') .. pad .. vim.json.encode(k) .. ': '
      encode(v[k], level + 1, out)
    end
    out[#out + 1] = '\n' .. (' '):rep(level) .. '}'
  else
    if #v == 0 then
      out[#out + 1] = '[]'
      return
    end
    out[#out + 1] = '['
    for i, item in ipairs(v) do
      out[#out + 1] = (i > 1 and ',' or '') .. pad
      encode(item, level + 1, out)
    end
    out[#out + 1] = '\n' .. (' '):rep(level) .. ']'
  end
end

---An output as the kernel sent it, converted to nbformat's on-disk shape: text split into
---lines, and stream text with its carriage returns already applied.
local function output_for_disk(o)
  o = vim.deepcopy(o)
  if o.output_type == 'stream' and type(o.text) == 'string' then
    local lines = display_lines(o.text)
    o.text = splitlines(table.concat(lines, '\n') .. (#lines > 0 and '\n' or ''))
  elseif o.data then
    for mime, value in pairs(o.data) do
      if type(value) == 'string' and mime ~= 'application/json' and not mime:match('%+json$') then
        o.data[mime] = splitlines(value)
      end
    end
  end
  return o
end

-- ---------------------------------------------------------------------------
-- Cells in the buffer

---Every cell in the buffer, top to bottom:
---  { row = header row (0-based, nil for code above the first header), type,
---    s, e = first/last body line (1-based, trailing blank lines excluded; e < s if empty),
---    data = the cell's stored state, or nil for a header typed since the last read }
local function scan(buf)
  local book = books[buf]
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local out, claimed = {}, {}

  local function push(c, last)
    c.e = last
    while c.e >= c.s and lines[c.e]:match('^%s*$') do
      c.e = c.e - 1
    end
    if c.row or c.e >= c.s then
      out[#out + 1] = c
    end
  end

  local cur = { s = 1, type = 'code' }
  for i, line in ipairs(lines) do
    if line:match(HEADER) then
      push(cur, i - 1)
      cur = { row = i - 1, s = i + 1, type = header_type(line) }
      -- invalidate = true hides the mark of a deleted header, so it is skipped here; and
      -- `claimed` stops two headers from sharing one cell's state.
      local marks = vim.api.nvim_buf_get_extmarks(buf, ns_cells, { i - 1, 0 }, { i - 1, -1 }, { details = true })
      for _, m in ipairs(marks) do
        if not m[4].invalid and book.cells[m[1]] and not claimed[m[1]] then
          claimed[m[1]] = true
          cur.data = book.cells[m[1]]
          break
        end
      end
    end
  end
  push(cur, #lines)
  return out, lines
end

---Attach state to a cell that has none yet (a header typed by hand).
local function ensure(buf, c)
  if c.data then
    return c.data
  end
  local book = books[buf]
  local data = { metadata = vim.empty_dict(), outputs = {} }
  if (book.meta.nbformat_minor or 0) >= 5 then
    data.id = new_id()
  end
  local mark = vim.api.nvim_buf_set_extmark(buf, ns_cells, c.row, 0, { invalidate = true })
  book.cells[mark] = data
  c.data = data
  return data
end

---scan(), but first give stray code above the first header a header of its own, so every
---cell has somewhere to keep its outputs.
local function cells(buf)
  local list, lines = scan(buf)
  if list[1] and not list[1].row then
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, { '# %%' })
    list, lines = scan(buf)
  end
  return list, lines
end

local function cell_at(list, row) -- row is 1-based
  local found = list[1]
  for _, c in ipairs(list) do
    if (c.row or 0) + 1 <= row then
      found = c
    end
  end
  return found
end

-- ---------------------------------------------------------------------------
-- Drawing outputs as virtual lines

local function elapsed(d)
  if not d.elapsed then
    return ''
  end
  local s = d.elapsed / 1e9
  if s < 60 then
    return (' %.1fs'):format(s)
  end
  return (' %dm %02ds'):format(math.floor(s / 60), math.floor(s % 60))
end

---{ text, hl } pairs for one output. `full` keeps whole tracebacks; the inline view
---shows only what is needed to see what went wrong.
local function output_entries(o, full)
  local out = {}
  local function add(text, group)
    for _, l in ipairs(display_lines(text)) do
      out[#out + 1] = { l, group }
    end
  end

  if o.output_type == 'stream' then
    add(join(o.text), o.name == 'stderr' and 'NotebookStderr' or 'NotebookOutput')
  elseif o.output_type == 'execute_result' or o.output_type == 'display_data' then
    local data = o.data or {}
    if data['text/plain'] then
      add(join(data['text/plain']), 'NotebookOutput')
    end
    for mime in pairs(data) do
      if mime:match('^image/') then
        out[#out + 1] = { ('[%s]%s'):format(mime, full and '  <CR> to open' or '  <leader>jo to view'), 'NotebookStatus' }
      end
    end
    if #out == 0 and next(data) then
      out[#out + 1] = { ('[%s]'):format(next(data)), 'NotebookStatus' }
    end
  elseif o.output_type == 'error' then
    if full then
      for _, entry in ipairs(o.traceback or {}) do
        add(entry, 'NotebookError')
      end
    else
      local evalue = display_lines(o.evalue or '')[1] or ''
      local summary = o.ename or 'Error'
      out[#out + 1] = { evalue ~= '' and summary .. ': ' .. evalue or summary, 'NotebookError' }
      -- Where it happened (IPython 8: "Cell In[3], line 2"), and for a Py4J error the
      -- JVM's innermost cause, which is what actually explains a failed Spark job.
      local cause
      for _, entry in ipairs(o.traceback or {}) do
        for _, l in ipairs(display_lines(entry)) do
          if l:match('^Cell In%[') then
            out[#out + 1] = { '  ' .. l, 'NotebookError' }
          end
        end
      end
      for _, l in ipairs(display_lines(o.evalue or '')) do
        if l:match('^Caused by:') then
          cause = l
        end
      end
      if cause then
        out[#out + 1] = { '  ' .. cause, 'NotebookError' }
      end
      out[#out + 1] = { '<leader>jo for the full traceback', 'NotebookStatus' }
    end
  end
  return out
end

local function status_line(d)
  local count = d.execution_count ~= vim.NIL and d.execution_count or nil
  if d.status == 'queued' then
    return '[ ] queued'
  elseif d.status == 'running' then
    return '[*] running'
  elseif d.status == 'aborted' then
    return 'not run: ' .. (d.reason or 'an earlier cell failed')
  end
  return ('[%s]%s'):format(count or ' ', elapsed(d))
end

-- Each cell is drawn as an open-right box, all of it virtual -- the buffer text is
-- untouched:
--
--   ╭─ [3] ─ cell 4/12 ──────────    over the '# %%' line (shown as-is while the cursor
--   │ df = spark.read.parquet(p)     is on it, so it can still be edited)
--   │ df.count()                     inline, shifting the code two columns right
--   ├─ out 2.1s ─────────────────    virtual lines under the cell's last line
--   │ 1204
--   ╰────────────────────────────
--
-- No right edge: lines longer than the window would break it. The rules are simply
-- longer than any window and get cut off at its edge.
local RULE = ('─'):rep(300)

local function header_label(c, d)
  if c.type ~= 'code' then
    return c.type
  end
  if d and d.status == 'running' then
    return '[*]'
  end
  local n = d and d.execution_count
  return ('[%s]'):format(n and n ~= vim.NIL and n or ' ')
end

---The label on the rule between a code cell and its output, or nil when the cell has
---never run in this session and has no saved output.
local function output_label(d)
  if d.status == 'queued' then
    return 'queued', 'NotebookStatus'
  elseif d.status == 'running' then
    return 'running', 'NotebookStatus'
  elseif d.status == 'aborted' then
    return 'not run: ' .. (d.reason or 'an earlier cell failed'), 'NotebookStatus'
  end
  for _, o in ipairs(d.outputs) do
    if o.output_type == 'error' then
      return 'error' .. elapsed(d), 'NotebookError'
    end
  end
  if #d.outputs > 0 then
    return 'out' .. elapsed(d), 'NotebookStatus'
  end
end

---The window showing `buf` whose cursor decides the active cell: the current one if it
---shows the buffer, else any.
local function cursor_row(buf)
  local win = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_buf(win) ~= buf then
    win = vim.fn.win_findbuf(buf)[1]
  end
  return win and vim.api.nvim_win_get_cursor(win)[1] or nil
end

---What about the cursor position changes the drawing: which cell is active, whether the
---cursor is on a header (shown raw), and whether it sits in the blank lines after a
---cell's code (the box stretches down to it, so new code is typed inside the box).
local function cursor_key(book, row)
  local idx
  for i, c in ipairs(book.layout or {}) do
    if c.start <= row then
      idx = i
    end
  end
  if not idx then
    return 'none'
  end
  local c = book.layout[idx]
  return ('%d:%s:%d'):format(idx, tostring(row == c.header), row > c.e and row or 0)
end

local function render(buf)
  local book = books[buf]
  if not vim.api.nvim_buf_is_valid(buf) or not book or book.raw then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, ns_out, 0, -1)
  local list = scan(buf)
  local cursor = cursor_row(buf)
  local active = cursor and cell_at(list, cursor)
  local mark = function(row, opts)
    vim.api.nvim_buf_set_extmark(buf, ns_out, row, 0, opts)
  end

  book.layout = {}
  for i, c in ipairs(list) do
    local d = c.data
    local border = c == active and 'NotebookBorderActive' or 'NotebookBorder'
    local label = header_label(c, d)

    -- The cursor in the blank lines below the active cell's code: stretch the box to it.
    local last = c.e
    local next_start = list[i + 1] and list[i + 1].row + 1 or math.huge
    if c == active and cursor > c.e and cursor < next_start then
      last = cursor
    end

    -- The top rule is two pieces. An overlay draws over closed folds too, so it holds only
    -- the prefix, which foldtext() repeats exactly; the rest of the rule is end-of-line
    -- text, which a closed fold hides -- letting foldtext's preview show through.
    local prefix = {
      { '╭─ ', border },
      { label, 'NotebookLabel' },
      { ' ─ ', border },
      { ('cell %d/%d'):format(i, #list), 'NotebookCellNumber' },
      { ' ', border },
    }
    if not c.row then
      mark(0, { virt_lines = { vim.list_extend(prefix, { { RULE, border } }) }, virt_lines_above = true })
    else
      if cursor ~= c.row + 1 then
        -- Past the end of '# %%' the two pieces overlap. The highest priority is drawn
        -- last; without it the order is whatever the extmark tree holds, and on some
        -- headers the rule wipes out the label.
        mark(c.row, { virt_text = prefix, virt_text_pos = 'overlay', priority = 5000 })
      end
      mark(c.row, { virt_text = { { RULE, border } }, virt_text_pos = 'eol' })
    end

    -- right_gravity = false keeps the bar left of anything typed at the start of a line.
    for r = c.s, last do
      mark(r - 1, { virt_text = { { '│ ', border } }, virt_text_pos = 'inline', right_gravity = false })
    end

    local virt = {}
    local out_label, out_hl = nil, nil
    if d and c.type == 'code' then
      out_label, out_hl = output_label(d)
    end
    if out_label then
      virt[1] = { { '├─ ', border }, { out_label, out_hl }, { ' ' .. RULE, border } }
      local entries = {}
      for _, o in ipairs(d.outputs) do
        vim.list_extend(entries, output_entries(o, false))
      end
      local hidden = #entries - MAX_LINES
      if hidden > 0 then
        entries = vim.list_slice(entries, 1, MAX_LINES)
        entries[#entries + 1] = { ('... %d more lines  <leader>jo to view'):format(hidden), 'NotebookStatus' }
      end
      for _, e in ipairs(entries) do
        virt[#virt + 1] = { { '│ ', border }, { e[1], e[2] } }
      end
      virt[#virt + 1] = { { '╰' .. RULE, border } }
    elseif d and c.type == 'code' and d.elapsed then
      -- Ran, printed nothing: the timing goes on the bottom rule.
      virt[1] = { { '╰─ ', border }, { 'ok' .. elapsed(d), 'NotebookStatus' }, { ' ' .. RULE, border } }
    else
      virt[1] = { { '╰' .. RULE, border } }
    end
    mark(last >= c.s and last - 1 or c.row or 0, { virt_lines = virt })

    book.layout[i] = { start = (c.row or 0) + 1, header = c.row and c.row + 1, e = c.e, label = label }
  end
  book.drawn_key = cursor and cursor_key(book, cursor)
end

---Fold per cell: each '# %%' line opens a fold that runs to the next one.
function M.foldexpr(lnum)
  return vim.fn.getline(lnum):match(HEADER) and '>1' or '='
end

---A closed cell keeps its top rule, plus a preview of its first line, so zM turns the
---notebook into an outline.
function M.foldtext()
  local buf = vim.api.nvim_get_current_buf()
  local start = vim.v.foldstart
  local layout = books[buf] and books[buf].layout or {}
  local idx, c = 0, nil
  for i, x in ipairs(layout) do
    if x.header == start then
      idx, c = i, x
    end
  end
  local body_end = c and c.e or vim.v.foldend
  local preview = ''
  for _, l in ipairs(vim.api.nvim_buf_get_lines(buf, start, body_end, false)) do
    if l:match('%S') then
      preview = vim.trim(l)
      break
    end
  end
  local n = math.max(body_end - start, 0)
  return {
    { '╭─ ', 'NotebookBorder' },
    { c and c.label or '# %%', 'NotebookLabel' },
    { ' ─ ', 'NotebookBorder' },
    { ('cell %d/%d'):format(idx, #layout), 'NotebookCellNumber' },
    { ' ─ ', 'NotebookBorder' }, -- render() overlays everything up to here, identically
    { preview, 'Normal' },
    { (' ─ %d line%s '):format(n, n == 1 and '' or 's'), 'NotebookCellNumber' },
    { RULE, 'NotebookBorder' },
  }
end

local function window_options()
  vim.opt_local.foldmethod = 'expr'
  vim.opt_local.foldexpr = "v:lua.require'core.notebook'.foldexpr(v:lnum)"
  vim.opt_local.foldtext = "v:lua.require'core.notebook'.foldtext()"
  vim.opt_local.foldlevel = 99 -- open on arrival; zM / zc close
  vim.opt_local.fillchars:append({ fold = ' ' })
end

-- Kernel output can arrive hundreds of times a second; redraw at most every 30ms.
local render_pending = {}
local function schedule_render(buf)
  if render_pending[buf] then
    return
  end
  render_pending[buf] = true
  vim.defer_fn(function()
    render_pending[buf] = nil
    render(buf)
  end, 30)
end

-- ---------------------------------------------------------------------------
-- The kernel

local BRIDGE -- the helper's source, defined at the bottom of the file

---The environment's interpreter: the kernel must run where the project's packages are.
local function python()
  for _, root in ipairs({ vim.env.VIRTUAL_ENV, vim.env.CONDA_PREFIX }) do
    if root and root ~= '' then
      -- A conda env on Windows keeps python.exe at its root, not in Scripts\.
      local candidates = is_win and { root .. '/Scripts/python.exe', root .. '/python.exe' }
        or { root .. '/bin/python', root .. '/bin/python3' }
      for _, p in ipairs(candidates) do
        if vim.fn.executable(p) == 1 then
          return vim.fs.normalize(p)
        end
      end
    end
  end
  -- On Windows, 'python3' is often the Microsoft Store stub; try 'python' first there.
  for _, name in ipairs(is_win and { 'python', 'python3' } or { 'python3', 'python' }) do
    local p = vim.fn.exepath(name)
    if p ~= '' then
      return p
    end
  end
end

---Write the helper next to Neovim's cache, only when its content changed.
local function bridge_path()
  local path = vim.fs.joinpath(vim.fn.stdpath('cache'), 'notebook_bridge.py')
  local f = io.open(path, 'rb')
  local current = f and f:read('*a')
  if f then
    f:close()
  end
  if current ~= BRIDGE then
    vim.fn.mkdir(vim.fs.dirname(path), 'p')
    f = assert(io.open(path, 'wb'))
    f:write(BRIDGE)
    f:close()
  end
  return path
end

local function log_path()
  return vim.fs.joinpath(vim.fn.stdpath('log'), 'notebook-kernel.log')
end

local function send(k, msg)
  vim.fn.chansend(k.job, vim.json.encode(msg) .. '\n')
end

---Mark every cell still waiting on the kernel as not run.
local function abort_pending(k, reason)
  for id, d in pairs(k.reqs) do
    d.status, d.reason = 'aborted', reason
    k.reqs[id] = nil
  end
end

local function on_event(buf, k, ev)
  local d = ev.id and k.reqs[ev.id]
  if ev.ev == 'ready' then
    vim.notify('notebook: kernel ready (' .. ev.python .. ')')
  elseif ev.ev == 'start' and d then
    d.status, d.started = 'running', vim.uv.hrtime()
    d.execution_count = ev.count
  elseif ev.ev == 'output' and d then
    if d.clear_on_output then
      d.outputs, d.clear_on_output = {}, nil
    end
    local last = d.outputs[#d.outputs]
    local o = ev.output
    -- Consecutive chunks of one stream are one output, as in Jupyter.
    if o.output_type == 'stream' and last and last.output_type == 'stream' and last.name == o.name then
      last.text = join(last.text) .. o.text
    else
      d.outputs[#d.outputs + 1] = o
    end
  elseif ev.ev == 'clear' and d then
    if ev.wait then
      d.clear_on_output = true
    else
      d.outputs = {}
    end
  elseif ev.ev == 'done' and d then
    k.reqs[ev.id] = nil
    d.status = ev.status == 'aborted' and 'aborted' or nil
    d.elapsed = d.started and vim.uv.hrtime() - d.started or nil
    d.started = nil
    if vim.api.nvim_buf_is_valid(buf) then
      vim.bo[buf].modified = true -- outputs changed; ZZ must not drop them silently
    end
  elseif ev.ev == 'dead' then
    abort_pending(k, 'the kernel died')
    vim.notify('notebook: the kernel died -- <leader>jR restarts it, :NotebookLog says why', vim.log.levels.ERROR)
  elseif ev.ev == 'restarted' then
    vim.notify('notebook: kernel restarted')
  elseif ev.ev == 'fatal' then
    abort_pending(k, 'the kernel did not start')
    vim.notify('notebook: ' .. ev.msg, vim.log.levels.ERROR)
  end
  schedule_render(buf)
end

local function start(buf)
  local book = books[buf]
  if book.kernel then
    return book.kernel
  end
  local py = python()
  if not py then
    vim.notify('notebook: no python found in the active environment or on PATH', vim.log.levels.ERROR)
    return nil
  end
  local cwd = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ':p:h')
  local k = { reqs = {}, seq = 0, partial = '', stderr = {} }

  k.job = vim.fn.jobstart({ py, bridge_path(), cwd, log_path() }, {
    cwd = cwd,
    on_stdout = function(_, data)
      -- Chunks split anywhere; the last element is always an incomplete line.
      data[1] = k.partial .. data[1]
      k.partial = table.remove(data)
      for _, line in ipairs(data) do
        local ok, ev = pcall(vim.json.decode, line)
        if ok and type(ev) == 'table' then
          on_event(buf, k, ev)
        end
      end
    end,
    on_stderr = function(_, data)
      vim.list_extend(k.stderr, data)
    end,
    on_exit = function(_, code)
      abort_pending(k, 'the kernel stopped')
      if books[buf] and books[buf].kernel == k then
        books[buf].kernel = nil
      end
      if code ~= 0 and not k.stopping then
        local tail = vim.list_slice(vim.tbl_filter(function(l)
          return l ~= ''
        end, k.stderr), -8)
        vim.notify('notebook: kernel helper exited (' .. code .. ')\n' .. table.concat(tail, '\n'), vim.log.levels.ERROR)
      end
      schedule_render(buf)
    end,
  })
  if k.job <= 0 then
    vim.notify('notebook: could not start ' .. py, vim.log.levels.ERROR)
    return nil
  end
  book.kernel = k
  vim.notify('notebook: starting kernel...')
  return k
end

---Stop the kernel. Closing stdin lets the helper shut the kernel down cleanly -- killing
---the helper outright could leave the kernel (and Spark's JVM) running.
local function stop(buf)
  local k = books[buf] and books[buf].kernel
  if not k then
    return
  end
  k.stopping = true
  pcall(vim.fn.chanclose, k.job, 'stdin')
  books[buf].kernel = nil
end

-- ---------------------------------------------------------------------------
-- Commands

local function run(buf, list, lines)
  local k = start(buf)
  if not k then
    return
  end
  for _, c in ipairs(list) do
    local code = c.e >= c.s and table.concat(lines, '\n', c.s, c.e) or ''
    -- Markdown and raw cells are not code; an empty cell is skipped, as Jupyter does.
    if c.type == 'code' and code:match('%S') then
      local d = ensure(buf, c)
      d.outputs, d.status, d.reason, d.elapsed, d.clear_on_output = {}, 'queued', nil, nil, nil
      k.seq = k.seq + 1
      k.reqs[k.seq] = d
      send(k, { op = 'execute', id = k.seq, code = code })
    end
  end
  schedule_render(buf)
end

local function goto_cell(c)
  vim.api.nvim_win_set_cursor(0, { math.min(c.row + 2, vim.api.nvim_buf_line_count(0)), 0 })
end

function M.run_cell(advance)
  local buf = vim.api.nvim_get_current_buf()
  local list, lines = cells(buf)
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local c = cell_at(list, row)
  if not c then
    return
  end
  run(buf, { c }, lines)
  if advance then
    local nxt
    for i, x in ipairs(list) do
      if x == c then
        nxt = list[i + 1]
      end
    end
    if nxt then
      goto_cell(nxt)
    else
      local n = vim.api.nvim_buf_line_count(buf)
      vim.api.nvim_buf_set_lines(buf, n, n, false, { '', '# %%', '' })
      vim.api.nvim_win_set_cursor(0, { n + 3, 0 })
    end
  end
end

function M.run_all(upto_cursor)
  local buf = vim.api.nvim_get_current_buf()
  local list, lines = cells(buf)
  if upto_cursor then
    local here = cell_at(list, vim.api.nvim_win_get_cursor(0)[1])
    local cut = {}
    for _, c in ipairs(list) do
      cut[#cut + 1] = c
      if c == here then
        break
      end
    end
    list = cut
  end
  run(buf, list, lines)
end

local function op(name, msg)
  return function()
    local k = books[vim.api.nvim_get_current_buf()].kernel
    if not k then
      vim.notify('notebook: no kernel running', vim.log.levels.WARN)
      return
    end
    if name == 'restart' then
      abort_pending(k, 'the kernel restarted')
    end
    send(k, { op = name })
    if msg then
      vim.notify('notebook: ' .. msg)
    end
  end
end

function M.clear(all)
  local buf = vim.api.nvim_get_current_buf()
  local list = scan(buf)
  local targets = all and list or { cell_at(list, vim.api.nvim_win_get_cursor(0)[1]) }
  for _, c in ipairs(targets) do
    if c and c.data and c.data.status ~= 'queued' and c.data.status ~= 'running' then
      c.data.outputs, c.data.execution_count, c.data.status, c.data.elapsed = {}, nil, nil, nil
    end
  end
  vim.bo[buf].modified = true
  render(buf)
end

function M.jump(dir)
  local list = scan(vim.api.nvim_get_current_buf())
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local here = cell_at(list, row)
  for i, c in ipairs(list) do
    if c == here then
      local target = list[i + dir]
      if dir < 0 and here.row and row > here.row + 2 then
        target = here -- like [[: first back to the start of this cell
      end
      if target and target.row then
        goto_cell(target)
      end
      return
    end
  end
end

function M.new_cell(type)
  local buf = vim.api.nvim_get_current_buf()
  local list = scan(buf)
  local c = cell_at(list, vim.api.nvim_win_get_cursor(0)[1])
  local at = c and math.max(c.e, c.row and c.row + 1 or 0) or vim.api.nvim_buf_line_count(buf)
  local body = type == 'markdown' and '# ' or ''
  vim.api.nvim_buf_set_lines(buf, at, at, false, { '', header_for(type), body })
  vim.api.nvim_win_set_cursor(0, { at + 3, #body })
  vim.cmd('startinsert!')
end

---Every output of the cell under the cursor, untruncated, in a scratch split.
function M.show_output()
  local buf = vim.api.nvim_get_current_buf()
  local c = cell_at(scan(buf), vim.api.nvim_win_get_cursor(0)[1])
  local d = c and c.data
  if not d or (#d.outputs == 0 and not d.status) then
    vim.notify('notebook: this cell has no output', vim.log.levels.INFO)
    return
  end
  local lines, images = { status_line(d) }, {}
  for _, o in ipairs(d.outputs) do
    for _, e in ipairs(output_entries(o, true)) do
      lines[#lines + 1] = e[1]
      local mime = e[1]:match('^%[(image/[%w%.%+%-]+)%]')
      if mime then
        images[#lines] = { mime = mime, data = join(o.data[mime]) }
      end
    end
  end

  vim.cmd('botright new')
  local out = vim.api.nvim_get_current_buf()
  vim.bo[out].buftype, vim.bo[out].bufhidden, vim.bo[out].swapfile = 'nofile', 'wipe', false
  vim.api.nvim_buf_set_lines(out, 0, -1, false, lines)
  vim.bo[out].modifiable = false
  vim.wo.wrap = false
  vim.keymap.set('n', 'q', '<Cmd>close<CR>', { buffer = out, nowait = true })
  vim.keymap.set('n', '<CR>', function()
    local img = images[vim.api.nvim_win_get_cursor(0)[1]]
    if not img then
      return
    end
    local ext = img.mime:match('image/(%w+)') or 'png'
    local path = vim.fn.tempname() .. '.' .. (ext == 'svg' and 'svg' or ext)
    local bytes = img.mime:match('svg') and img.data or vim.base64.decode((img.data:gsub('%s', '')))
    local f = assert(io.open(path, 'wb'))
    f:write(bytes)
    f:close()
    vim.ui.open(path)
  end, { buffer = out })
end

-- ---------------------------------------------------------------------------
-- Reading and writing .ipynb

-- One table drives both the mappings and the legend, so the two cannot drift apart.
-- Each entry: key after <leader>j, legend text, action.
local ACTIONS = {
  { 'x', 'run cell', function() M.run_cell(false) end },
  { 'n', 'run cell, go to next', function() M.run_cell(true) end },
  { 'a', 'run all', function() M.run_all(false) end },
  { 'A', 'run all up to here', function() M.run_all(true) end },
  { 'i', 'interrupt kernel', op('interrupt', 'interrupt sent') },
  { 'R', 'restart kernel', op('restart', 'restarting kernel...') },
  { 'o', 'full output in split', function() M.show_output() end },
  { 'c', 'clear cell output', function() M.clear(false) end },
  { 'C', 'clear all output', function() M.clear(true) end },
  { 'b', 'new code cell below', function() M.new_cell('code') end },
  { 'm', 'new markdown cell below', function() M.new_cell('markdown') end },
}

-- Shown in the legend for reference; these are plain mappings or built-in commands.
local OTHER_KEYS = {
  { ']j [j', 'next / previous cell' },
  { 'zc zo', 'fold / open a cell' },
  { 'zM zR', 'fold all (outline) / open all' },
}

---The legend, which-key style: <leader>j on its own -- i.e. a pause after it longer than
---'timeoutlen' -- opens it, and the next key runs that action. Typing <leader>jx in one go
---never shows it. <Esc> or any other key closes it.
function M.legend()
  local lines, marks = {}, {}
  local key_w = 7
  for i = 1, #ACTIONS, 2 do
    local row = {}
    for j = i, math.min(i + 1, #ACTIONS) do
      local a = ACTIONS[j]
      row[#row + 1] = ('  %s  %-24s'):format(a[1], a[2])
      marks[#marks + 1] = { #lines, (j - i) * 29 + 2, 1, 'NotebookBorderActive' }
    end
    lines[#lines + 1] = table.concat(row)
  end
  lines[#lines + 1] = ''
  for _, o in ipairs(OTHER_KEYS) do
    lines[#lines + 1] = ('  %-' .. key_w .. 's%s'):format(o[1], o[2])
    marks[#marks + 1] = { #lines - 1, 2, #o[1], 'NotebookBorderActive' }
    marks[#marks + 1] = { #lines - 1, 2 + key_w, #o[2], 'NotebookStatus' }
  end

  local width = 0
  for i, l in ipairs(lines) do
    lines[i] = l:gsub('%s+$', '')
    width = math.max(width, vim.fn.strdisplaywidth(lines[i]) + 2)
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  local ns = vim.api.nvim_create_namespace('notebook-legend')
  for _, m in ipairs(marks) do
    vim.api.nvim_buf_set_extmark(buf, ns, m[1], m[2], { end_col = m[2] + m[3], hl_group = m[4] })
  end

  -- Bottom-right of the current window, clear of the code being worked on.
  local win = vim.api.nvim_open_win(buf, false, {
    relative = 'win',
    anchor = 'SE',
    row = vim.api.nvim_win_get_height(0),
    col = vim.api.nvim_win_get_width(0),
    width = width,
    height = #lines,
    style = 'minimal',
    border = 'rounded',
    title = ' <leader>j ',
    title_pos = 'center',
    noautocmd = true,
  })
  vim.wo[win].winhighlight = 'NormalFloat:Normal,FloatBorder:NotebookBorder,FloatTitle:NotebookLabel'
  vim.cmd('redraw')

  local ok, key = pcall(vim.fn.getcharstr)
  pcall(vim.api.nvim_win_close, win, true)
  pcall(vim.api.nvim_buf_delete, buf, { force = true })
  if not ok then
    return
  end
  for _, a in ipairs(ACTIONS) do
    if a[1] == key then
      a[3]()
      return
    end
  end
end

local function keymaps(buf)
  local map = function(lhs, fn, desc)
    vim.keymap.set('n', lhs, fn, { buffer = buf, desc = 'Notebook: ' .. desc })
  end
  for _, a in ipairs(ACTIONS) do
    map('<leader>j' .. a[1], a[3], a[2])
  end
  map('<leader>j', M.legend, 'show the notebook keymaps')
  map(']j', function() M.jump(1) end, 'next cell')
  map('[j', function() M.jump(-1) end, 'previous cell')
end

local function read(buf, path)
  local nb
  if vim.fn.filereadable(path) == 1 then
    local f = assert(io.open(path, 'rb'))
    local text = f:read('*a')
    f:close()
    local ok, decoded = pcall(vim.json.decode, text)
    if not ok or type(decoded) ~= 'table' or type(decoded.cells) ~= 'table' then
      -- Not a notebook we understand: show the JSON as-is and write it back as-is.
      books[buf] = { raw = true }
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(text, '\r?\n'))
      vim.bo[buf].filetype = 'json'
      vim.bo[buf].modified = false
      vim.notify('notebook: could not parse ' .. vim.fn.fnamemodify(path, ':t') .. ', showing raw JSON', vim.log.levels.WARN)
      return
    end
    nb = decoded
  else
    nb = {
      cells = {},
      metadata = {
        kernelspec = { display_name = 'Python 3', language = 'python', name = 'python3' },
        language_info = { name = 'python' },
      },
      nbformat = 4,
      nbformat_minor = 5,
    }
  end

  local old = books[buf]
  local book = { meta = nb, cells = {}, kernel = old and old.kernel }
  books[buf] = book
  local raw_cells = nb.cells
  nb.cells = nil

  local lines, headers = {}, {}
  for i, cell in ipairs(raw_cells) do
    if i > 1 then
      lines[#lines + 1] = ''
    end
    local type = cell.cell_type == 'markdown' and 'markdown' or cell.cell_type == 'raw' and 'raw' or 'code'
    lines[#lines + 1] = header_for(type)
    headers[#headers + 1] = { row = #lines - 1, cell = cell }
    local src = join(cell.source)
    if src ~= '' then
      for _, l in ipairs(vim.split(src, '\n', { plain = true })) do
        lines[#lines + 1] = type == 'markdown' and (l == '' and '#' or '# ' .. l) or l
      end
    end
  end
  if #lines == 0 then
    lines = { '# %%', '' }
  end

  vim.api.nvim_buf_clear_namespace(buf, ns_cells, 0, -1)
  -- No swap file. Neovim creates it on the first change, which here is this load -- and if
  -- one is left over from a crash, its "ATTENTION" prompt cannot be answered from inside
  -- an autocmd, so it aborts the load and the notebook never opens. A swap file of the
  -- script view could not be recovered into the .ipynb anyway.
  vim.bo[buf].swapfile = false
  -- No undo history for the load itself: `u` must not empty the buffer.
  local ul = vim.bo[buf].undolevels
  vim.bo[buf].undolevels = -1
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].undolevels = ul

  for _, h in ipairs(headers) do
    local cell = h.cell
    local mark = vim.api.nvim_buf_set_extmark(buf, ns_cells, h.row, 0, { invalidate = true })
    book.cells[mark] = {
      id = cell.id,
      metadata = cell.metadata or vim.empty_dict(),
      attachments = cell.attachments,
      outputs = cell.outputs or {},
      execution_count = cell.execution_count ~= vim.NIL and cell.execution_count or nil,
    }
  end

  vim.bo[buf].modified = false
  vim.bo[buf].filetype = 'python'
  if not old then
    keymaps(buf)
    -- Immediately, not via schedule_render: a new line drawn without its bar for even
    -- one frame makes the code visibly jump two columns.
    vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI' }, {
      buffer = buf,
      callback = function()
        render(buf)
      end,
    })
    vim.api.nvim_create_autocmd({ 'CursorMoved', 'CursorMovedI' }, {
      buffer = buf,
      callback = function()
        local b = books[buf]
        if b and cursor_key(b, vim.api.nvim_win_get_cursor(0)[1]) ~= b.drawn_key then
          render(buf)
        end
      end,
    })
    vim.api.nvim_create_autocmd('BufWinEnter', { buffer = buf, callback = window_options })
    vim.api.nvim_create_autocmd({ 'BufUnload' }, {
      buffer = buf,
      once = true,
      callback = function()
        stop(buf)
        books[buf] = nil
      end,
    })
  end
  render(buf)
end

local function write(buf, path)
  local book = books[buf]
  local text
  if not book or book.raw then
    text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n') .. '\n'
  else
    local list, lines = scan(buf)
    local out_cells = {}
    for _, c in ipairs(list) do
      local d = c.data or {}
      local body = c.e >= c.s and vim.list_slice(lines, c.s, c.e) or {}
      if c.type == 'markdown' then
        for i, l in ipairs(body) do
          body[i] = l:gsub('^# ?', '')
        end
      end
      local cell = {
        cell_type = c.type,
        metadata = d.metadata or vim.empty_dict(),
        source = splitlines(table.concat(body, '\n')),
      }
      if d.id then
        cell.id = d.id
      elseif (book.meta.nbformat_minor or 0) >= 5 then
        cell.id = new_id()
      end
      if c.type == 'code' then
        cell.execution_count = d.execution_count or vim.NIL
        cell.outputs = vim.tbl_map(output_for_disk, d.outputs or {})
      elseif c.type == 'markdown' and d.attachments then
        cell.attachments = d.attachments
      end
      out_cells[#out_cells + 1] = cell
    end

    local nb = vim.deepcopy(book.meta)
    nb.cells = out_cells
    local parts = {}
    encode(nb, 0, parts)
    text = table.concat(parts) .. '\n'
  end

  local f, err = io.open(path, 'wb')
  if not f then
    vim.notify('notebook: cannot write ' .. path .. ': ' .. tostring(err), vim.log.levels.ERROR)
    return
  end
  f:write(text)
  f:close()
  -- :w other.ipynb is a copy; only a write to the buffer's own file makes it unmodified.
  if vim.fs.normalize(vim.fn.fnamemodify(path, ':p')) == vim.fs.normalize(vim.api.nvim_buf_get_name(buf)) then
    vim.bo[buf].modified = false
  end
  vim.api.nvim_echo({ { ('"%s" %dB written'):format(vim.fn.fnamemodify(path, ':~:.'), #text) } }, false, {})
end

local group = vim.api.nvim_create_augroup('notebook', { clear = true })
vim.api.nvim_create_autocmd('BufReadCmd', {
  group = group,
  pattern = '*.ipynb',
  callback = function(args)
    read(args.buf, vim.fn.fnamemodify(args.match, ':p'))
  end,
})
vim.api.nvim_create_autocmd('BufWriteCmd', {
  group = group,
  pattern = '*.ipynb',
  callback = function(args)
    write(args.buf, vim.fn.fnamemodify(args.match, ':p'))
  end,
})
-- Closing stdin on exit, rather than leaving Neovim to kill the helper, lets it shut the
-- kernel down cleanly.
vim.api.nvim_create_autocmd('VimLeavePre', {
  group = group,
  callback = function()
    for buf in pairs(books) do
      stop(buf)
    end
  end,
})

vim.api.nvim_create_user_command('NotebookLog', function()
  vim.cmd('split ' .. vim.fn.fnameescape(log_path()))
  vim.cmd('normal! G')
end, { desc = 'Open the notebook kernel log' })
vim.api.nvim_create_user_command('NotebookStop', function()
  stop(vim.api.nvim_get_current_buf())
end, { desc = 'Shut down this notebook kernel' })

-- ---------------------------------------------------------------------------
-- The helper, written to stdpath('cache') and run with the environment's python.
-- JSON lines in both directions:
--
--   nvim -> helper  {op = execute, id, code} | {op = interrupt} | {op = restart} | {op = shutdown}
--   helper -> nvim  {ev = ready, python} | {ev = start, id, count} | {ev = output, id, output}
--                   {ev = clear, id, wait} | {ev = done, id, status} | {ev = dead}
--                   {ev = restarted} | {ev = fatal, msg}

BRIDGE = [==[
import json
import queue
import signal
import sys
import threading

terminated = False


def emit(**ev):
    # ensure_ascii keeps the pipe pure ASCII, whatever the console codepage is.
    sys.stdout.buffer.write(json.dumps(ev).encode("ascii") + b"\n")
    sys.stdout.buffer.flush()


def read_stdin(q):
    # Bytes, decoded as UTF-8: on Windows sys.stdin would use the ANSI codepage.
    for raw in sys.stdin.buffer:
        try:
            q.put(json.loads(raw.decode("utf-8")))
        except ValueError:
            pass
    q.put(None)


def on_term(*_):
    global terminated
    terminated = True
    sys.exit(0)


def main():
    cwd, log_path = sys.argv[1], sys.argv[2]
    try:
        from jupyter_client import KernelManager
        from jupyter_client.kernelspec import KernelSpec, KernelSpecManager
    except ImportError as e:
        emit(ev="fatal", msg=f"{e} (install jupyter_client and ipykernel into {sys.executable})")
        return

    class Spec(KernelSpecManager):
        # Always this interpreter -- never a kernelspec registered elsewhere on the machine.
        def get_kernel_spec(self, kernel_name):
            return KernelSpec(
                argv=[sys.executable, "-m", "ipykernel_launcher", "-f", "{connection_file}"],
                display_name="Python",
                language="python",
            )

    log = open(log_path, "ab")
    km = KernelManager(kernel_spec_manager=Spec(), kernel_name="nvim")
    kc = None
    pending = {}  # msg_id -> {"id": nvim's id, "idle": bool, "status": reply status}

    def finish(msg_id):
        p = pending.pop(msg_id)
        emit(ev="done", id=p["id"], status=p["status"] or "ok")

    try:
        try:
            # The kernel's own stdout/stderr (and Spark's JVM, its child) go to the log:
            # inheriting ours would corrupt the JSON stream.
            km.start_kernel(cwd=cwd, stdout=log, stderr=log)
            kc = km.client()
            kc.start_channels()
            kc.wait_for_ready(timeout=120)
        except Exception as e:
            emit(ev="fatal", msg=f"kernel failed to start: {e} -- :NotebookLog has its output")
            return
        emit(ev="ready", python=sys.executable)

        q = queue.Queue()
        threading.Thread(target=read_stdin, args=(q,), daemon=True).start()
        alive = True

        while True:
            try:
                while True:
                    cmd = q.get_nowait()
                    if cmd is None:
                        return  # Neovim went away
                    op = cmd.get("op")
                    if op == "execute":
                        msg_id = kc.execute(cmd["code"], allow_stdin=False)
                        pending[msg_id] = {"id": cmd["id"], "idle": False, "status": None}
                    elif op == "interrupt":
                        km.interrupt_kernel()
                    elif op == "restart":
                        pending.clear()
                        km.restart_kernel(now=False)
                        kc.wait_for_ready(timeout=120)
                        alive = True
                        emit(ev="restarted")
                    elif op == "shutdown":
                        return
            except queue.Empty:
                pass

            # Shell replies carry the status, and are the only signal for a request the
            # kernel aborted because an earlier one failed.
            try:
                while True:
                    reply = kc.get_shell_msg(timeout=0)
                    msg_id = reply["parent_header"].get("msg_id")
                    p = pending.get(msg_id)
                    if p is not None:
                        p["status"] = reply["content"].get("status", "ok")
                        if p["idle"] or p["status"] == "aborted":
                            finish(msg_id)
            except queue.Empty:
                pass

            try:
                msg = kc.get_iopub_msg(timeout=0.05)
            except queue.Empty:
                msg = None
            if msg is not None:
                msg_id = msg["parent_header"].get("msg_id")
                p = pending.get(msg_id)
                t, c = msg["msg_type"], msg["content"]
                if p is None:
                    pass
                elif t == "execute_input":
                    emit(ev="start", id=p["id"], count=c.get("execution_count"))
                elif t == "stream":
                    out = {"output_type": "stream", "name": c["name"], "text": c["text"]}
                    emit(ev="output", id=p["id"], output=out)
                elif t in ("execute_result", "display_data"):
                    out = {"output_type": t, "data": c.get("data", {}), "metadata": c.get("metadata", {})}
                    if t == "execute_result":
                        out["execution_count"] = c.get("execution_count")
                    emit(ev="output", id=p["id"], output=out)
                elif t == "error":
                    out = {"output_type": "error", "ename": c["ename"], "evalue": c["evalue"],
                           "traceback": c["traceback"]}
                    emit(ev="output", id=p["id"], output=out)
                elif t == "clear_output":
                    emit(ev="clear", id=p["id"], wait=c.get("wait", False))
                elif t == "status" and c.get("execution_state") == "idle":
                    p["idle"] = True
                    if p["status"] is not None:
                        finish(msg_id)

            if alive and not km.is_alive():
                alive = False
                pending.clear()
                emit(ev="dead")
    finally:
        if km.has_kernel:
            km.shutdown_kernel(now=terminated)


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, on_term)
    signal.signal(signal.SIGINT, signal.SIG_IGN)
    main()
]==]

return M
