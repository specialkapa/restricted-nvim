-- Hive from Neovim: run HiveQL, browse the schema, complete names. No plugins.
--
-- A small helper (BRIDGE, at the bottom of this file) run with the active environment's
-- python does the talking -- the same arrangement as core.notebook -- through one of:
--
--   beeline  a long-lived beeline per connection, so whatever beeline can reach works:
--            ZooKeeper discovery, HTTP transport, SSL, Kerberos. The JDBC URL is
--            vim.g.hive.uri, else $HIVE_URI, else built from hive-site.xml (vim.g.hive.hive_site,
--            else $HIVE_CONF_DIR, $SPARK_CONF_DIR, $SPARK_HOME/conf, $HIVE_HOME/conf).
--            Kerberos: kinit first. The default when vim.g.hive has no host.
--
--              vim.g.hive = { driver = 'beeline' }
--              -- optional: uri = 'jdbc:hive2://...', hive_site = '/path/hive-site.xml',
--              -- beeline = '/path/to/beeline', database = 'default', connect_timeout = 180
--
--            Starting beeline takes a few seconds per connection. Display queries get
--            LIMIT <hive_limit + 1> appended, since rows can't be cut off mid-stream.
--
--   pyhive / impyla  HiveServer2's binary Thrift port, directly:
--
--   vim.g.hive = {
--     host = 'hive.example.com', port = 10000,
--     username = 'me', database = 'default',
--     auth = 'KERBEROS',              -- NONE | NOSASL | LDAP | CUSTOM | KERBEROS
--     kerberos_service_name = 'hive', -- KERBEROS only
--     -- password = '...',            -- LDAP / CUSTOM; asked for once per session if unset
--     -- driver = 'impyla',           -- default: pyhive if it imports, else impyla
--     -- configuration = { ['hive.execution.engine'] = 'tez' },  -- session settings
--     -- kwargs = {},                 -- passed as-is to connect()
--   }
--
-- <leader>hu (or :Hive) opens the workspace, a tab page laid out like vim-dadbod-ui:
--
--   ┌────────────────┬───────────────────────────┐
--   │ hive:10000 ●   │ scratch.sql               │  query editor: plain .sql files
--   │ + New query    │ select * from sales.orders│  in stdpath('data')/hive/
--   │ ▸ Saved queries│ where amount > 10;        │
--   │ ▾ Databases    ├───────────────────────────┤
--   │   ▾ sales      │ order_id │ customer │ ... │  results
--   │     ▾ orders   │        1 │ acme     │     │
--   │         » preview, count, describe, ...    │
--   └────────────────┴───────────────────────────┘
--
-- <leader>hu again (or q in the browser) closes the tab; the buffers stay loaded.
-- <leader>1 / 2 / 3 go to the browser / editor / results from anywhere (numbered in
-- their winbars), reopening a pane you closed; <Tab> / <S-Tab> in the browser and
-- results step through the panes (not in the editor: there <Tab> is <C-i>).
-- Browser: <CR> expands a node, opens a query, runs a table helper or inserts a column;
-- e puts the helper's SQL in the editor to edit first; on a table p preview, n count,
-- d describe, P partitions, c DDL; i inserts the name; D deletes a saved query;
-- R reloads the node; C reconnects. Opening the workspace connects.
--
--   <leader>hr  run the statement under the cursor (statements end at `;`); in visual
--               mode every statement in the selected lines. The last result set shows.
--   <leader>hc  cancel the running query        <leader>ho  show the results window
--   <leader>hb  the browser alone, in this tab  <leader>hh  query history
--   <leader>hs  scratch.sql in this window
--
-- All of these work outside the workspace too, on any .sql / .hql buffer.
--
-- In .sql / .hql buffers <C-x><C-o> (and the autotrigger in core.completion) completes
-- keywords, databases, tables (`db.`) and columns (`tbl.` / `alias.`, or bare for the
-- tables the statement reads). Schema is fetched on first use while connected, then
-- cached; :HiveRefresh forgets it.
--
-- Results window: <CR> the row as a record, s sort by the column under the cursor (again
-- to reverse), e re-run the query into a CSV file (every row, not just those shown),
-- E write the rows shown to CSV, r re-run, <C-c> cancel, q close.
--
-- There are two connections: one runs your queries, the other loads schema, so the
-- browser and completion keep working while a long query runs.
--
--   :HiveConnect  reconnect, re-reading vim.g.hive   :HiveDisconnect
--   :HiveRun      run the statement under the cursor, or the lines of a range
--   :HiveLog      the helper's stderr (driver warnings, tracebacks)

local M = {}

local LIMIT = 1000 -- rows fetched for display; vim.g.hive_limit overrides
local MAXW = 40 -- widest a column is drawn; <CR> shows the full value

local is_win = vim.fn.has('win32') == 1
local ns = vim.api.nvim_create_namespace('hive')
local WARN, ERROR = vim.log.levels.WARN, vim.log.levels.ERROR

-- The helper process, started on first use.
--   reqs     id -> callback(ev) awaiting its reply
--   running  the query feeding the results window, while it runs
local S = { job = nil, seq = 0, reqs = {}, partial = '', stderr = {} }
-- Schema, keyed 'dbs' / 'tables:<db>' / 'cols:<db>.<tbl>'. `loading` holds the callbacks
-- waiting on a key already asked for.
local cache, loading = {}, {}
local current_db -- follows USE
local R = { buf = nil, data = nil, sort = nil, starts = {} } -- the results window
local B = { buf = nil, open = {}, rows = {} } -- the schema browser
local W = { tab = nil, editor = nil } -- the workspace tab page and its editor window

local function in_workspace()
  return W.tab ~= nil and vim.api.nvim_tabpage_is_valid(W.tab) and vim.api.nvim_get_current_tabpage() == W.tab
end

local function notify(msg, level)
  vim.notify('hive: ' .. msg, level)
end

local function hl()
  local set = function(name, link)
    vim.api.nvim_set_hl(0, name, { link = link, default = true })
  end
  set('HiveHeader', 'Title')
  set('HiveSep', 'Comment')
  set('HiveNull', 'Comment')
  set('HiveError', 'DiagnosticError')
  set('HiveDb', 'Directory')
  set('HiveTable', 'Identifier')
  set('HiveType', 'Comment')
  set('HiveHelper', 'Function')
end
hl()
vim.api.nvim_create_autocmd('ColorScheme', { callback = hl })

local dw = vim.fn.strdisplaywidth

local function commas(n)
  return (tostring(n):reverse():gsub('(%d%d%d)', '%1,'):reverse():gsub('^,', ''))
end

local function db_name()
  return current_db or (type(vim.g.hive) == 'table' and vim.g.hive.database) or 'default'
end

---Backticks only where Hive needs them, so history stays readable.
local function q(name)
  return name:match('^[%w_]+$') and name or '`' .. name .. '`'
end

-- ---------------------------------------------------------------------------
-- The helper

local BRIDGE -- the helper's source, defined at the bottom of the file

---The environment's interpreter: PyHive / impyla live where the project's packages are.
local function python()
  for _, root in ipairs({ vim.env.VIRTUAL_ENV, vim.env.CONDA_PREFIX }) do
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
end

---Write the helper next to Neovim's cache, only when its content changed.
local function bridge_path()
  local path = vim.fs.joinpath(vim.fn.stdpath('cache'), 'hive_bridge.py')
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

local function config()
  local cfg = vim.g.hive
  if type(cfg) ~= 'table' then
    notify("set vim.g.hive first, e.g. { driver = 'beeline' } (see lua/core/hive.lua)", ERROR)
    return nil
  end
  local auth = (cfg.auth or 'NONE'):upper()
  if (auth == 'LDAP' or auth == 'CUSTOM') and not cfg.password then
    if not S.password then
      local pw = vim.fn.inputsecret('Hive password for ' .. (cfg.username or '?') .. ': ')
      if pw == '' then
        return nil
      end
      S.password = pw
    end
    cfg.password = S.password
  end
  return cfg
end

local function fail_all(msg)
  local reqs = S.reqs
  S.reqs = {}
  for _, cb in pairs(reqs) do
    cb({ ev = 'error', msg = msg })
  end
end

local update_winbar -- defined with the results window

local function on_event(ev)
  if ev.ev == 'connected' then
    if not S.connected then
      S.connected = true
      notify('connected (' .. ev.driver .. ')')
      M.render_browser()
    end
  elseif ev.ev == 'log' then
    if S.running and S.running.id == ev.id then
      S.running.log = ev.line
      update_winbar()
    end
  else
    local cb = S.reqs[ev.id]
    S.reqs[ev.id] = nil
    if cb then
      cb(ev)
    end
  end
end

local function start()
  if S.job then
    return true
  end
  local cfg = config()
  local py = cfg and python()
  if not cfg then
    return false
  elseif not py then
    notify('no python found in the active environment or on PATH', ERROR)
    return false
  end
  S.partial, S.stderr, S.connected = '', {}, false
  local job
  job = vim.fn.jobstart({ py, bridge_path() }, {
    on_stdout = function(_, data)
      if S.job ~= job then
        return -- a helper replaced by :HiveConnect
      end
      -- Chunks split anywhere; the last element is always an incomplete line.
      data[1] = S.partial .. data[1]
      S.partial = table.remove(data)
      for _, line in ipairs(data) do
        local ok, ev = pcall(vim.json.decode, line)
        if ok and type(ev) == 'table' then
          on_event(ev)
        end
      end
    end,
    on_stderr = function(_, data)
      vim.list_extend(S.stderr, data)
      if #S.stderr > 500 then
        S.stderr = vim.list_slice(S.stderr, #S.stderr - 300)
      end
    end,
    on_exit = function(_, code)
      if S.job == job then
        S.job = nil
        fail_all('the helper exited (' .. code .. ') -- :HiveLog says why')
        M.render_browser()
      end
    end,
  })
  if job <= 0 then
    notify('could not start ' .. py, ERROR)
    return false
  end
  S.job = job
  M.render_browser()
  -- The config goes over stdin, not argv, so a password never shows up in `ps`.
  vim.fn.chansend(job, vim.json.encode(cfg) .. '\n')
  return true
end

---Send a request; cb(ev) gets its reply ({ev = result | exported | error, ...}).
local function request(req, cb)
  if not start() then
    return nil
  end
  S.seq = S.seq + 1
  req.id = S.seq
  S.reqs[req.id] = cb
  vim.fn.chansend(S.job, vim.json.encode(req) .. '\n')
  return req.id
end

---Closing stdin makes the helper cancel what is running and close its connections.
function M.disconnect(wait)
  local job = S.job
  if not job then
    return
  end
  S.job = nil
  pcall(vim.fn.chanclose, job, 'stdin')
  if wait then
    vim.fn.jobwait({ job }, 3000)
  end
  vim.defer_fn(function()
    pcall(vim.fn.jobstop, job)
  end, 10000)
  fail_all('disconnected')
end

function M.connect()
  M.disconnect()
  S.password = nil
  if start() then
    request({ op = 'ping', lane = 'query' }, function(ev)
      if ev.ev == 'error' then
        notify(ev.msg, ERROR)
      end
    end)
  end
end

-- ---------------------------------------------------------------------------
-- Statements

---Split SQL at `;` outside quotes and comments; comments are dropped, since some
---HiveServer2 versions choke on them.
---@return {sql: string, s: integer, e: integer}[]  s, e: first and last line with code
function M.split(lines, first)
  first = first or 1
  local out, buf, state, s, last = {}, {}, nil, nil, nil
  for i, line in ipairs(lines) do
    local lnum = first + i - 1
    local j = 1
    while j <= #line do
      local c, two = line:sub(j, j), line:sub(j, j + 1)
      if state == 'block' then
        if two == '*/' then
          state, j = nil, j + 1
          buf[#buf + 1] = ' '
        end
      elseif state then -- inside a quote; state is the quote character
        buf[#buf + 1] = c
        if c == '\\' and state ~= '`' then
          buf[#buf + 1] = line:sub(j + 1, j + 1)
          j = j + 1
        elseif c == state then
          state = nil
        end
        last = lnum
      elseif two == '--' then
        break
      elseif two == '/*' then
        state, j = 'block', j + 1
      elseif c == ';' then
        if s then
          out[#out + 1] = { sql = vim.trim(table.concat(buf)), s = s, e = lnum }
        end
        buf, s = {}, nil
      else
        if c:match('%S') then
          s, last = s or lnum, lnum
        end
        if c == "'" or c == '"' or c == '`' then
          state = c
        end
        buf[#buf + 1] = c
      end
      j = j + 1
    end
    buf[#buf + 1] = '\n'
  end
  if s then
    out[#out + 1] = { sql = vim.trim(table.concat(buf)), s = s, e = last }
  end
  return out
end

---The statement under the cursor: the last one starting at or above it.
local function statement_at_cursor()
  local lnum = vim.fn.line('.')
  local stmts = M.split(vim.api.nvim_buf_get_lines(0, 0, -1, false))
  local found = stmts[1]
  for _, st in ipairs(stmts) do
    if st.s <= lnum then
      found = st
    end
  end
  return found
end

local function flash(s, e)
  pcall(vim.hl.range, 0, ns, 'IncSearch', { s - 1, 0 }, { e - 1, 0 }, { regtype = 'V', timeout = 200 })
end

-- ---------------------------------------------------------------------------
-- History, one JSON object per line

local function history_path()
  return vim.fs.joinpath(vim.fn.stdpath('data'), 'hive_history.jsonl')
end

local function add_history(entry)
  vim.fn.mkdir(vim.fs.dirname(history_path()), 'p')
  local f = io.open(history_path(), 'a')
  if f then
    f:write(vim.json.encode(entry) .. '\n')
    f:close()
  end
end

-- ---------------------------------------------------------------------------
-- The results window

local function results_buf()
  if R.buf and vim.api.nvim_buf_is_valid(R.buf) then
    return R.buf
  end
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(b, 'hive://results')
  vim.bo[b].filetype = 'hiveresult'
  vim.bo[b].modifiable = false
  vim.api.nvim_buf_call(b, function()
    -- Alternatives, not a [...] class: retyped as ASCII, [|-+] would be a reverse range.
    vim.cmd([[syntax match HiveSep /\V│\|─\|┼/]])
    vim.cmd([[syntax match HiveNull /\<NULL\>/]])
  end)
  local map = function(lhs, fn, desc)
    vim.keymap.set('n', lhs, fn, { buffer = b, desc = desc, nowait = true })
  end
  map('q', '<Cmd>close<CR>', 'Close')
  map('<CR>', function()
    M.record()
  end, 'Row as a record')
  map('s', function()
    M.sort()
  end, 'Sort by this column')
  map('e', function()
    M.export()
  end, 'Re-run into a CSV file')
  map('E', function()
    M.write_csv()
  end, 'Write the rows shown to CSV')
  map('r', function()
    if R.data and R.data.stmts then
      M.run(R.data.stmts)
    end
  end, 'Re-run')
  map('<C-c>', function()
    M.cancel()
  end, 'Cancel the query')
  map('<Tab>', function()
    M.cycle(1)
  end, 'Next pane')
  map('<S-Tab>', function()
    M.cycle(-1)
  end, 'Previous pane')
  vim.bo[b].modifiable = true
  vim.api.nvim_buf_set_lines(b, 0, -1, false, { '-- results show here: <leader>hr in the editor runs the statement under the cursor' })
  vim.bo[b].modifiable = false
  R.buf = b
  return b
end

---The results window, opened at the bottom if needed. Focus stays put unless asked.
local function results_window(focus)
  local b = results_buf()
  local win = vim.fn.bufwinid(b)
  if win == -1 then
    local prev = vim.api.nvim_get_current_win()
    if in_workspace() and W.editor and vim.api.nvim_win_is_valid(W.editor) then
      vim.api.nvim_set_current_win(W.editor) -- under the editor, not the browser
      vim.cmd('belowright ' .. (vim.g.hive_height or 15) .. 'split')
    else
      vim.cmd('botright ' .. (vim.g.hive_height or 15) .. 'split')
    end
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, b)
    local wo = vim.wo[win]
    wo.wrap, wo.number, wo.relativenumber, wo.list, wo.spell = false, false, false, false, false
    wo.cursorline, wo.signcolumn, wo.winfixheight = true, 'no', true
    if not focus then
      vim.api.nvim_set_current_win(prev)
    end
  elseif focus then
    vim.api.nvim_set_current_win(win)
  end
  update_winbar()
  return win
end

-- The connection status in the browser: filled / hollow circle, and an ellipsis.
local ON, OFF, DOTS = vim.fn.nr2char(0x25CF), vim.fn.nr2char(0x25CB), vim.fn.nr2char(0x2026)

-- Braille spinner frames, by code point so the file stays ASCII here.
local SPIN = vim.tbl_map(vim.fn.nr2char, { 0x280B, 0x2819, 0x2839, 0x2838, 0x283C, 0x2834, 0x2826, 0x2827, 0x2807, 0x280F })

local function status()
  local esc = function(s)
    return (s:gsub('%%', '%%%%'))
  end
  local run = S.running
  if run then
    local secs = math.floor((vim.uv.hrtime() - run.started) / 1e9)
    local what = run.export and 'exporting' or run.cancelling and 'cancelling' or 'running'
    return (' %s %s %ds  %s%%=<C-c> cancel '):format(SPIN[secs % #SPIN + 1], what, secs, esc(run.log or ''))
  end
  local d = R.data
  if not d then
    return ' no query yet'
  elseif d.error then
    return (' failed after %.1fs'):format(d.secs)
  end
  local sql = esc(d.stmts[#d.stmts]:gsub('%s+', ' '))
  if #d.columns == 0 then
    return (' done in %.1fs · %s'):format(d.secs, sql)
  end
  local n = #d.rows
  local sorted = R.sort and (' · by %s %s'):format(esc(d.columns[R.sort.col]), R.sort.desc and '↓' or '↑') or ''
  return (' %s row%s%s · %.1fs%s · %s%%=<CR> record  s sort  e/E csv  r rerun ')
    :format(commas(n), n == 1 and '' or 's', d.truncated and ' (limit)' or '', d.secs, sorted, sql)
end

update_winbar = function()
  if R.buf and vim.api.nvim_buf_is_valid(R.buf) then
    for _, win in ipairs(vim.fn.win_findbuf(R.buf)) do
      vim.wo[win].winbar = ' [3]' .. status()
    end
  end
end

local timer
local function ticking(on)
  timer = timer or vim.uv.new_timer()
  if on then
    timer:start(0, 1000, vim.schedule_wrap(update_winbar))
  else
    timer:stop()
  end
end

local function set_lines(lines)
  local b = results_buf()
  vim.bo[b].modifiable = true
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  vim.bo[b].modifiable = false
  vim.api.nvim_buf_clear_namespace(b, ns, 0, -1)
  return b
end

---Cut `s` to `w` display cells, marking the cut with an ellipsis.
local function fit(s, w)
  if dw(s) <= w then
    return s
  end
  local n = vim.fn.strchars(s)
  local out = vim.fn.strcharpart(s, 0, w - 1)
  while dw(out) > w - 1 and n > 0 do
    n = n - 1
    out = vim.fn.strcharpart(out, 0, n)
  end
  return out .. '…'
end

local function pad(s, w, right)
  local gap = string.rep(' ', w - dw(s))
  return right and gap .. s or s .. gap
end

local function render()
  local d = R.data
  if d.error then
    local b = set_lines(vim.split(d.error, '\n'))
    vim.hl.range(b, ns, 'HiveError', { 0, 0 }, { vim.api.nvim_buf_line_count(b) - 1, 0 }, { regtype = 'V' })
    return update_winbar()
  elseif #d.columns == 0 then
    set_lines({ '-- done; the last statement returned no rows' })
    return update_winbar()
  end
  local ncol, widths, numeric, cells = #d.columns, {}, {}, {}
  for c = 1, ncol do
    widths[c], numeric[c] = dw(d.columns[c]), true
  end
  for r, row in ipairs(d.rows) do
    local line = {}
    for c = 1, ncol do
      local v = row[c]
      if v == vim.NIL then
        line[c] = 'NULL'
      else
        line[c] = v:gsub('\r?\n', '↵'):gsub('\t', ' ')
        numeric[c] = numeric[c] and tonumber(v) ~= nil
      end
      widths[c] = math.min(MAXW, math.max(widths[c], dw(line[c])))
    end
    cells[r] = line
  end
  local function fmt(vals)
    local parts = {}
    for c = 1, ncol do
      parts[c] = pad(fit(vals[c], widths[c]), widths[c], numeric[c])
    end
    return (table.concat(parts, ' │ '):gsub('%s+$', ''))
  end
  local sep = {}
  R.starts = { 1 }
  for c = 1, ncol do
    sep[c] = string.rep('─', widths[c])
    R.starts[c + 1] = R.starts[c] + widths[c] + 3 -- ' │ ' is three cells wide
  end
  local lines = { fmt(d.columns), table.concat(sep, '─┼─') }
  for r = 1, #cells do
    lines[r + 2] = fmt(cells[r])
  end
  local b = set_lines(lines)
  vim.api.nvim_buf_set_extmark(b, ns, 0, 0, { end_col = #lines[1], hl_group = 'HiveHeader' })
  update_winbar()
end

local function finished(run, ev)
  if S.running == run then
    S.running = nil
    ticking(false)
  end
  local secs = (vim.uv.hrtime() - run.started) / 1e9
  if run.export then
    if ev.ev == 'error' then
      notify('export failed: ' .. ev.msg, ERROR)
    else
      notify(('wrote %s rows to %s'):format(commas(ev.rows), ev.path))
    end
    return update_winbar()
  end
  add_history({
    time = os.time(),
    sql = table.concat(run.stmts, ';\n') .. ';',
    secs = secs,
    rows = ev.rows and #ev.rows or nil,
    error = ev.ev == 'error' and ev.msg or nil,
  })
  R.sort = nil
  if ev.ev == 'error' then
    R.data = { error = ev.msg, secs = secs, stmts = run.stmts }
  else
    for _, st in ipairs(run.stmts) do
      local db = st:match('^[Uu][Ss][Ee]%s+`?([%w_]+)`?$')
      current_db = db and db:lower() or current_db
    end
    -- HiveServer2 names columns `tbl.col`; the table part is noise in a grid.
    local cols = ev.columns
    if #cols > 0 and #vim.tbl_filter(function(c)
      return c:find('.', 1, true) ~= nil
    end, cols) == #cols then
      cols = vim.tbl_map(function(c)
        return c:match('[^.]+$')
      end, cols)
    end
    R.data = { columns = cols, rows = ev.rows, truncated = ev.truncated, secs = secs, stmts = run.stmts }
  end
  render()
end

---Run statements (strings, without the `;`) and show the last result set.
---opts.export = path re-runs into a CSV file instead.
function M.run(stmts, opts)
  opts = opts or {}
  if #stmts == 0 then
    return notify('nothing to run', WARN)
  elseif S.running then
    return notify('a query is already running (<leader>hc cancels it)', WARN)
  end
  local run = { stmts = stmts, started = vim.uv.hrtime(), export = opts.export }
  local req = { op = opts.export and 'export' or 'query', lane = 'query', stmts = stmts }
  req.limit, req.path = vim.g.hive_limit or LIMIT, opts.export
  run.id = request(req, function(ev)
    finished(run, ev)
  end)
  if run.id then
    S.running = run
    results_window()
    ticking(true)
  end
end

function M.run_cursor()
  local st = statement_at_cursor()
  if not st then
    return notify('nothing to run', WARN)
  end
  flash(st.s, st.e)
  M.run({ st.sql })
end

function M.run_lines(l1, l2)
  local stmts = M.split(vim.api.nvim_buf_get_lines(0, l1 - 1, l2, false), l1)
  flash(l1, l2)
  M.run(vim.tbl_map(function(st)
    return st.sql
  end, stmts))
end

function M.cancel()
  if not (S.running and S.job) then
    return notify('nothing is running')
  end
  S.running.cancelling = true
  vim.fn.chansend(S.job, vim.json.encode({ op = 'cancel' }) .. '\n')
  update_winbar()
end

function M.show()
  if not R.data then
    return notify('no results yet')
  end
  results_window(true)
end

---The row under the cursor in a float, one `column  value` per line, values in full.
function M.record()
  local d = R.data
  local row = d and d.rows and d.rows[vim.fn.line('.') - 2]
  if not row then
    return
  end
  local w = 0
  for _, c in ipairs(d.columns) do
    w = math.max(w, dw(c))
  end
  local lines, width = {}, 20
  for c, name in ipairs(d.columns) do
    local v = row[c] == vim.NIL and 'NULL' or row[c]
    for i, part in ipairs(vim.split(v, '\n')) do
      lines[#lines + 1] = (i == 1 and pad(name, w) or string.rep(' ', w)) .. '  ' .. part
      width = math.max(width, dw(lines[#lines]))
    end
  end
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  for i, line in ipairs(lines) do
    if line:sub(1, 1) ~= ' ' then
      vim.api.nvim_buf_set_extmark(b, ns, i - 1, 0, { end_col = #line:match('^%S+'), hl_group = 'HiveTable' })
    end
  end
  vim.bo[b].modifiable = false
  width = math.min(width + 1, vim.o.columns - 6)
  local height = math.min(#lines, vim.o.lines - 8)
  local win = vim.api.nvim_open_win(b, true, {
    relative = 'editor',
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2),
    border = 'rounded',
    title = (' row %d of %d '):format(vim.fn.line('.') - 2, #d.rows),
  })
  vim.wo[win].wrap, vim.wo[win].linebreak = true, true
  for _, lhs in ipairs({ 'q', '<Esc>' }) do
    vim.keymap.set('n', lhs, '<Cmd>close<CR>', { buffer = b, nowait = true })
  end
end

function M.sort()
  local d = R.data
  if not (d and d.columns and #d.columns > 0) then
    return
  end
  local vc, c = vim.fn.virtcol('.'), 1
  for i = 1, #d.columns do
    if vc >= R.starts[i] then
      c = i
    end
  end
  local desc = R.sort ~= nil and R.sort.col == c and not R.sort.desc
  -- NULLs last either way; numbers as numbers when both sides are.
  pcall(table.sort, d.rows, function(a, b)
    local x, y = a[c], b[c]
    if x == vim.NIL or y == vim.NIL then
      return x ~= vim.NIL and y == vim.NIL
    end
    local nx, ny = tonumber(x), tonumber(y)
    if nx and ny then
      x, y = nx, ny
    end
    if desc then
      return x > y
    end
    return x < y
  end)
  R.sort = { col = c, desc = desc }
  render()
  vim.api.nvim_win_set_cursor(0, { math.min(3, vim.api.nvim_buf_line_count(0)), 0 })
  vim.fn.cursor(0, vim.fn.virtcol2col(0, vim.fn.line('.'), R.starts[c]))
end

local function ask_path(cb)
  vim.ui.input({ prompt = 'CSV file: ', default = vim.fn.getcwd() .. '/result.csv', completion = 'file' }, function(p)
    if p and p ~= '' then
      cb(vim.fs.normalize(vim.fn.fnamemodify(vim.fn.expand(p), ':p')))
    end
  end)
end

function M.export()
  local d = R.data
  if d and d.stmts then
    ask_path(function(path)
      M.run(d.stmts, { export = path })
    end)
  end
end

function M.write_csv()
  local d = R.data
  if not (d and d.rows) then
    return
  end
  local function csv(v)
    if v == vim.NIL then
      return ''
    end
    return v:find('[",\r\n]') and '"' .. v:gsub('"', '""') .. '"' or v
  end
  ask_path(function(path)
    local lines = { table.concat(vim.tbl_map(csv, d.columns), ',') }
    for _, row in ipairs(d.rows) do
      lines[#lines + 1] = table.concat(vim.tbl_map(csv, row), ',')
    end
    if vim.fn.writefile(lines, path) == 0 then
      notify(('wrote %s rows to %s'):format(commas(#d.rows), path))
    end
  end)
end

-- ---------------------------------------------------------------------------
-- Schema

---Fetch `key` with `sql` on the schema connection, once; cb(value) when it is there.
local function meta(key, sql, parse, cb)
  if cache[key] then
    return cb(cache[key])
  elseif loading[key] then
    if not vim.tbl_contains(loading[key], cb) then
      table.insert(loading[key], cb)
    end
    return
  end
  loading[key] = { cb }
  local id = request({ op = 'query', lane = 'meta', stmts = { sql }, limit = 100000 }, function(ev)
    local cbs = loading[key]
    loading[key] = nil
    if ev.ev == 'error' then
      return notify(sql .. ': ' .. ev.msg, ERROR)
    end
    cache[key] = parse(ev.rows)
    for _, f in ipairs(cbs) do
      f(cache[key])
    end
  end)
  if not id then
    loading[key] = nil
  end
end

local function first_col(rows)
  return vim.tbl_map(function(r)
    return r[1]
  end, rows)
end

function M.databases(cb)
  meta('dbs', 'SHOW DATABASES', first_col, cb)
end

function M.tables(db, cb)
  meta('tables:' .. db, 'SHOW TABLES IN ' .. q(db), first_col, cb)
end

function M.columns(db, tbl, cb)
  meta('cols:' .. db .. '.' .. tbl, 'DESCRIBE ' .. q(db) .. '.' .. q(tbl), function(rows)
    -- Columns come first; a blank or `# Partition Information` row ends them.
    local cols = {}
    for _, r in ipairs(rows) do
      local name = r[1] ~= vim.NIL and vim.trim(r[1]) or ''
      if name == '' or name:sub(1, 1) == '#' then
        break
      end
      cols[#cols + 1] = { name = name, type = r[2] ~= vim.NIL and vim.trim(r[2]) or '' }
    end
    return cols
  end, cb)
end

function M.refresh()
  cache = {}
  if B.buf and vim.fn.bufwinid(B.buf) ~= -1 then
    M.render_browser()
  end
  notify('schema cache cleared')
end

-- ---------------------------------------------------------------------------
-- The workspace: a tab page laid out like dadbod-ui
--
--   ┌──────────┬─────────────────────┐
--   │ browser  │ query editor        │
--   │          ├─────────────────────┤
--   │          │ results             │
--   └──────────┴─────────────────────┘
--
-- The editor holds ordinary .sql files kept in stdpath('data')/hive/ -- scratch.sql and
-- the queries you start from the browser -- so :w saves them and they show up under
-- "Saved queries" next time.

local function query_dir()
  local dir = vim.fs.joinpath(vim.fn.stdpath('data'), 'hive')
  vim.fn.mkdir(dir, 'p')
  return dir
end

---The window queries go to: the workspace editor, else the window you came from.
local function editor_win()
  if in_workspace() and W.editor and vim.api.nvim_win_is_valid(W.editor) then
    return W.editor
  end
  vim.cmd('wincmd p')
  return vim.api.nvim_get_current_win()
end

local function open_in_editor(path)
  vim.api.nvim_set_current_win(editor_win())
  vim.cmd.edit(vim.fn.fnameescape(path))
end

---Put `sql` at the end of the editor's buffer, cursor on it, ready to edit and run.
local function to_editor(sql)
  vim.api.nvim_set_current_win(editor_win())
  local last = vim.api.nvim_buf_line_count(0)
  local lines = vim.split(sql .. ';', '\n')
  if vim.api.nvim_buf_get_lines(0, last - 1, last, false)[1] ~= '' then
    table.insert(lines, 1, '')
  end
  vim.api.nvim_buf_set_lines(0, last, last, false, lines)
  vim.api.nvim_win_set_cursor(0, { vim.api.nvim_buf_line_count(0), 0 })
end

local function saved_queries()
  local files = vim.fn.glob(vim.fs.joinpath(query_dir(), '*.sql'), false, true)
  table.sort(files, function(a, b)
    return vim.fn.getftime(a) > vim.fn.getftime(b)
  end)
  return files
end

-- What a table offers when expanded; <CR> runs one, e puts it in the editor instead.
local HELPERS = {
  { 'preview', 'SELECT * FROM %s LIMIT 100' },
  { 'count', 'SELECT COUNT(*) FROM %s' },
  { 'describe', 'DESCRIBE FORMATTED %s' },
  { 'partitions', 'SHOW PARTITIONS %s' },
  { 'ddl' },
}

function M.render_browser()
  local b = B.buf
  if not (b and vim.api.nvim_buf_is_valid(b)) then
    return
  end
  local lines, rows, marks = {}, {}, {}
  -- One line: `prefix`, `name` in `group`, then `suffix` dimmed.
  local function add(prefix, name, group, row, suffix)
    lines[#lines + 1] = prefix .. name .. (suffix or '')
    rows[#lines] = row or {}
    marks[#marks + 1] = { #lines - 1, #prefix, #prefix + #name, group }
    if suffix then
      marks[#marks + 1] = { #lines - 1, #prefix + #name, #lines[#lines], 'HiveType' }
    end
  end
  local arrow = function(key)
    return B.open[key] and '▾ ' or '▸ '
  end
  local render = M.render_browser

  local cfg = type(vim.g.hive) == 'table' and vim.g.hive or {}
  local where = cfg.host and ('%s:%s'):format(cfg.host, cfg.port or 10000) or 'hive (beeline)'
  add(' ', where, 'HiveHeader', {},
    S.job and (S.connected and '  ' .. ON .. ' connected' or '  ' .. OFF .. ' connecting' .. DOTS) or '  ' .. OFF .. ' not connected')
  add('', '', nil)
  add('+ ', 'New query', 'HiveHelper', { kind = 'new' })
  local files = saved_queries()
  add(arrow('#saved'), 'Saved queries', 'HiveDb', { kind = 'node', key = '#saved' }, ' (' .. #files .. ')')
  for _, f in ipairs(B.open['#saved'] and files or {}) do
    add('    ', vim.fn.fnamemodify(f, ':t'), 'Normal', { kind = 'file', path = f }, '  ' .. os.date('%m-%d %H:%M', vim.fn.getftime(f)))
  end

  local dbs = cache.dbs
  if B.open['#dbs'] and not dbs then
    M.databases(render)
  end
  add(arrow('#dbs'), 'Databases', 'HiveDb', { kind = 'node', key = '#dbs' }, dbs and ' (' .. #dbs .. ')' or nil)
  if B.open['#dbs'] and not dbs then
    add('    ', 'loading…', 'HiveType')
  end
  for _, db in ipairs(B.open['#dbs'] and dbs or {}) do
    add('  ' .. arrow(db), db, 'HiveDb', { kind = 'node', key = db, db = db })
    local tables = B.open[db] and cache['tables:' .. db]
    if B.open[db] and not tables then
      M.tables(db, render)
      add('      ', 'loading…', 'HiveType')
    elseif tables and #tables == 0 then
      add('      ', '(no tables)', 'HiveType')
    end
    for _, tbl in ipairs(tables or {}) do
      local key = db .. '.' .. tbl
      add('    ' .. arrow(key), tbl, 'HiveTable', { kind = 'node', key = key, db = db, tbl = tbl })
      if B.open[key] then
        for _, h in ipairs(HELPERS) do
          add('        » ', h[1], 'HiveHelper', { kind = 'helper', helper = h, db = db, tbl = tbl })
        end
        local cols = cache['cols:' .. key]
        if not cols then
          M.columns(db, tbl, render)
          add('        ', 'loading…', 'HiveType')
        end
        local w = 0
        for _, c in ipairs(cols or {}) do
          w = math.max(w, dw(c.name))
        end
        for _, c in ipairs(cols or {}) do
          add('        ', c.name, 'Normal', { kind = 'col', db = db, tbl = tbl, col = c.name },
            string.rep(' ', w - dw(c.name) + 2) .. c.type)
        end
      end
    end
  end

  B.rows = rows
  vim.bo[b].modifiable = true
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  vim.bo[b].modifiable = false
  vim.api.nvim_buf_clear_namespace(b, ns, 0, -1)
  for _, m in ipairs(marks) do
    if m[4] and m[3] > m[2] then
      vim.api.nvim_buf_set_extmark(b, ns, m[1], m[2], { end_col = m[3], hl_group = m[4] })
    end
  end
end

local function browser_row()
  return B.rows[vim.fn.line('.')] or {}
end

function M.ddl(db, tbl)
  local fq = q(db) .. '.' .. q(tbl)
  request({ op = 'query', lane = 'meta', stmts = { 'SHOW CREATE TABLE ' .. fq }, limit = 100000 }, function(ev)
    if ev.ev == 'error' then
      return notify(ev.msg, ERROR)
    end
    local name = 'hive://ddl/' .. db .. '.' .. tbl
    local b = vim.fn.bufnr(name)
    if b == -1 then
      b = vim.api.nvim_create_buf(true, true)
      vim.api.nvim_buf_set_name(b, name)
    end
    vim.api.nvim_buf_set_lines(b, 0, -1, false, first_col(ev.rows))
    vim.api.nvim_win_set_buf(editor_win(), b)
    vim.bo[b].filetype = 'sql'
  end)
end

---Run a table helper, or with `edit` put its SQL in the editor instead.
local function helper(r, h, edit)
  if h[1] == 'ddl' then
    return M.ddl(r.db, r.tbl)
  end
  local sql = h[2]:format(q(r.db) .. '.' .. q(r.tbl))
  if edit then
    to_editor(sql)
  else
    M.run({ sql })
  end
end

function M.new_query()
  open_in_editor(vim.fs.joinpath(query_dir(), os.date('query-%Y%m%d-%H%M%S.sql')))
end

local function browser_buf()
  if B.buf and vim.api.nvim_buf_is_valid(B.buf) then
    return B.buf
  end
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(b, 'hive://schema')
  vim.bo[b].filetype = 'hivebrowser'
  vim.bo[b].modifiable = false
  local map = function(lhs, fn, desc)
    vim.keymap.set('n', lhs, fn, { buffer = b, desc = desc, nowait = true })
  end
  local function activate()
    local r = browser_row()
    if r.kind == 'node' then
      B.open[r.key] = not B.open[r.key]
      M.render_browser()
    elseif r.kind == 'new' then
      M.new_query()
    elseif r.kind == 'file' then
      open_in_editor(r.path)
    elseif r.kind == 'helper' then
      helper(r, r.helper)
    elseif r.kind == 'col' then
      vim.api.nvim_set_current_win(editor_win())
      vim.api.nvim_put({ r.col }, 'c', true, true)
    end
  end
  ---A table-level key: works on the table's line and anything under it.
  local function on_table(i)
    return function()
      local r = browser_row()
      if r.tbl then
        helper(r, HELPERS[i])
      end
    end
  end
  map('<CR>', activate, 'Open / run / insert')
  map('o', activate, 'Open / run / insert')
  map('e', function()
    local r = browser_row()
    if r.tbl then
      helper(r, r.helper or HELPERS[1], true)
    end
  end, "Put the helper's SQL in the editor")
  map('p', on_table(1), 'Preview rows')
  map('n', on_table(2), 'Count rows')
  map('d', on_table(3), 'Describe formatted')
  map('P', on_table(4), 'Partitions')
  map('c', on_table(5), 'SHOW CREATE TABLE in the editor')
  map('i', function()
    local r = browser_row()
    local name = r.col or r.tbl and r.db .. '.' .. r.tbl or r.db
    if name then
      vim.api.nvim_set_current_win(editor_win())
      vim.api.nvim_put({ name }, 'c', true, true)
    end
  end, 'Insert the name in the editor')
  map('D', function()
    local r = browser_row()
    if r.kind == 'file' and vim.fn.confirm('Delete ' .. vim.fn.fnamemodify(r.path, ':t') .. '?', '&Yes\n&No', 2) == 1 then
      vim.fn.delete(r.path)
      M.render_browser()
    end
  end, 'Delete a saved query')
  map('R', function()
    local r = browser_row()
    if r.tbl then
      cache['cols:' .. r.db .. '.' .. r.tbl] = nil
    elseif r.db then
      cache['tables:' .. r.db] = nil
    else
      cache = {}
    end
    M.render_browser()
  end, 'Reload this node')
  map('C', M.connect, 'Reconnect')
  map('<Tab>', function()
    M.cycle(1)
  end, 'Next pane')
  map('<S-Tab>', function()
    M.cycle(-1)
  end, 'Previous pane')
  map('q', function()
    if in_workspace() then
      M.workspace()
    else
      vim.cmd('close')
    end
  end, 'Close')
  B.buf = b
  return b
end

local function browser_window(win)
  vim.api.nvim_win_set_buf(win, browser_buf())
  local wo = vim.wo[win]
  wo.number, wo.relativenumber, wo.wrap, wo.list, wo.spell = false, false, false, false, false
  wo.cursorline, wo.signcolumn, wo.winfixwidth = true, 'no', true
  wo.winbar = ' [1] %#HiveHeader#Hive%*  <CR> open/run  e edit  i insert  R reload'
  B.open['#dbs'] = B.open['#dbs'] ~= false
  M.render_browser()
end

---The browser alone, in a split at the left of the current tab.
function M.browser()
  local win = vim.fn.bufwinid(browser_buf())
  if win ~= -1 then
    return vim.api.nvim_win_close(win, false)
  end
  vim.cmd('topleft ' .. (vim.g.hive_browser_width or 40) .. 'vsplit')
  browser_window(vim.api.nvim_get_current_win())
end

local function editor_window(win)
  W.editor = win
  vim.wo[win].winbar = ' [2] %t%m%=<leader>hr run  <leader>hc cancel  <leader>hu close '
end

---Open the workspace tab, go to it, or (from inside it) close it again.
function M.workspace()
  if W.tab and vim.api.nvim_tabpage_is_valid(W.tab) then
    if not in_workspace() then
      return vim.api.nvim_set_current_tabpage(W.tab)
    elseif #vim.api.nvim_list_tabpages() > 1 then
      return vim.cmd('tabclose')
    end
    return notify('the workspace is the only tab; :tabnew first to leave it')
  end
  vim.cmd.tabedit(vim.fn.fnameescape(vim.fs.joinpath(query_dir(), 'scratch.sql')))
  W.tab = vim.api.nvim_get_current_tabpage()
  editor_window(vim.api.nvim_get_current_win())
  results_window()
  vim.cmd('topleft ' .. (vim.g.hive_browser_width or 40) .. 'vsplit')
  browser_window(vim.api.nvim_get_current_win())
  vim.api.nvim_set_current_win(W.editor)
end

-- Panes, numbered as in their winbars: 1 browser, 2 editor, 3 results.

---Go to pane `n` of the workspace, opening the workspace or reopening the pane if needed.
function M.focus(n)
  if not in_workspace() then
    M.workspace()
  end
  if n == 1 then
    local win = vim.fn.bufwinid(browser_buf())
    if win == -1 then
      vim.cmd('topleft ' .. (vim.g.hive_browser_width or 40) .. 'vsplit')
      browser_window(vim.api.nvim_get_current_win())
    else
      vim.api.nvim_set_current_win(win)
    end
  elseif n == 2 then
    if not (W.editor and vim.api.nvim_win_is_valid(W.editor)) then
      -- Back where it was: above the results, else right of the browser.
      local results, browser = vim.fn.bufwinid(results_buf()), vim.fn.bufwinid(browser_buf())
      if results ~= -1 then
        vim.api.nvim_set_current_win(results)
        vim.cmd('aboveleft split')
      elseif browser ~= -1 then
        vim.api.nvim_set_current_win(browser)
        vim.cmd('rightbelow vsplit')
        vim.wo.winfixwidth, vim.wo.winbar = false, ''
      end
      vim.cmd.edit(vim.fn.fnameescape(vim.fs.joinpath(query_dir(), 'scratch.sql')))
      editor_window(vim.api.nvim_get_current_win())
      if browser ~= -1 then
        vim.api.nvim_win_set_width(browser, vim.g.hive_browser_width or 40) -- the split halved it
      end
    end
    vim.api.nvim_set_current_win(W.editor)
  else
    results_window(true)
  end
end

---Step through the panes: +1 forward, -1 back.
function M.cycle(step)
  local buf = vim.api.nvim_get_current_buf()
  local cur = buf == B.buf and 1 or buf == R.buf and 3 or 2
  M.focus((cur - 1 + step) % 3 + 1)
end

-- ---------------------------------------------------------------------------
-- Completion

local KEYWORDS = vim.split(
  'select distinct from where and or not in is null like rlike between exists case when then else end as'
    .. ' join inner left right full outer cross semi anti on using group by having order sort distribute'
    .. ' cluster limit union all insert into overwrite table partition values create external drop alter'
    .. ' view database if show tables describe formatted with lateral explode posexplode over rows range'
    .. ' count sum avg min max coalesce nvl cast concat concat_ws substr regexp_replace regexp_extract'
    .. ' date_format from_unixtime unix_timestamp to_date datediff date_add date_sub current_date'
    .. ' current_timestamp collect_list collect_set size split row_number rank dense_rank lag lead'
    .. ' first_value last_value percentile_approx get_json_object set use stored location tblproperties'
    .. ' string int bigint double decimal boolean timestamp date array map struct',
  ' '
)

-- Words that can follow a table name and are not its alias.
local NOT_ALIAS = {}
for _, w in ipairs(vim.split('where join on left right inner outer full cross semi anti group order sort'
  .. ' cluster distribute limit union lateral having window select insert tablesample', ' ')) do
  NOT_ALIAS[w] = true
end

---Tables the statement reads: name or alias -> 'db.tbl'.
local function referenced(sql)
  local toks = {}
  for tok in sql:lower():gsub('`', ''):gsub('([,()])', ' %1 '):gmatch('%S+') do
    toks[#toks + 1] = tok
  end
  local refs, i = {}, 1
  while i <= #toks do
    if toks[i] == 'from' or toks[i] == 'join' then
      while true do -- `from a x, b y` lists several
        local name = toks[i + 1]
        if not (name and (name:match('^[%a_][%w_]*$') or name:match('^[%a_][%w_]*%.[%a_][%w_]*$'))) then
          break
        end
        local fq = name:find('.', 1, true) and name or db_name() .. '.' .. name
        refs[name:match('[^.]+$')] = fq
        i = i + 1
        if toks[i + 1] == 'as' then
          i = i + 1
        end
        local alias = toks[i + 1]
        if alias and alias:match('^[%a_][%w_]*$') and not NOT_ALIAS[alias] then
          refs[alias], i = fq, i + 1
        end
        if toks[i + 1] ~= ',' then
          break
        end
        i = i + 1
      end
    end
    i = i + 1
  end
  return refs
end

---Completion items for `qual.` (or everything in scope when qual is nil). Schema that is
---not cached yet is fetched -- when connected -- and `done` called once it arrives.
local function candidates(qual, done)
  local items, waiting, seen = {}, false, {}
  local function push(word, kind, menu)
    if not seen[word] then
      seen[word] = true
      items[#items + 1] = { word = word, kind = kind, menu = menu, icase = 1 }
    end
  end
  local function get(key, load)
    if cache[key] == nil and S.job then
      waiting = true
      load(done)
    end
    return cache[key]
  end
  local function columns(fq)
    local db, tbl = fq:match('^([^.]+)%.([^.]+)$')
    local tables = db and get('tables:' .. db, function(cb)
      M.tables(db, cb)
    end)
    if tables and vim.tbl_contains(tables, tbl) then
      local cols = get('cols:' .. fq, function(cb)
        M.columns(db, tbl, cb)
      end)
      for _, c in ipairs(cols or {}) do
        push(c.name, 'column', c.type)
      end
    end
  end
  local st = statement_at_cursor()
  local refs = referenced(st and st.sql or '')
  local dbs = get('dbs', M.databases) or {}
  if qual and vim.tbl_contains(dbs, qual) then
    local tables = get('tables:' .. qual, function(cb)
      M.tables(qual, cb)
    end)
    for _, t in ipairs(tables or {}) do
      push(t, 'table', qual)
    end
  elseif qual then
    columns(refs[qual] or (qual:find('.', 1, true) and qual) or db_name() .. '.' .. qual)
  else
    for _, fq in pairs(refs) do
      columns(fq)
    end
    local db = db_name()
    for _, t in ipairs(get('tables:' .. db, function(cb)
      M.tables(db, cb)
    end) or {}) do
      push(t, 'table', db)
    end
    for _, d in ipairs(dbs) do
      push(d, 'database')
    end
    for _, k in ipairs(KEYWORDS) do
      push(k, 'keyword')
    end
  end
  return items, waiting
end

local items -- between the omnifunc's two calls

function M.omnifunc(findstart, base)
  if findstart == 0 then
    local upper = base:match('%a') and base == base:upper()
    base = base:lower():gsub('`', '')
    local out = {}
    for _, it in ipairs(items or {}) do
      if vim.startswith(it.word:lower(), base) then
        if upper and it.kind == 'keyword' then
          it = vim.tbl_extend('force', it, { word = it.word:upper() })
        end
        out[#out + 1] = it
      end
    end
    return out
  end
  local before = vim.api.nvim_get_current_line():sub(1, vim.fn.col('.') - 1)
  local word = before:match('[%w_%.`]*$')
  local qual = word:match('^(.*)%.')
  qual = qual and qual:gsub('`', ''):lower()
  local buf, pos, fired = vim.api.nvim_get_current_buf(), vim.api.nvim_win_get_cursor(0), false
  -- Reopen the menu once missing schema arrives, if you are still where you were.
  local function done()
    vim.schedule(function()
      if fired or vim.api.nvim_get_current_buf() ~= buf or vim.fn.mode() ~= 'i' or vim.fn.pumvisible() == 1 then
        return
      end
      if vim.deep_equal(vim.api.nvim_win_get_cursor(0), pos) then
        fired = true
        vim.api.nvim_feedkeys(vim.keycode('<C-x><C-o>'), 'n', false)
      end
    end)
  end
  local waiting
  items, waiting = candidates(qual, done)
  if #items == 0 and waiting then
    return -3 -- quietly; done() reopens it
  end
  return #before - #word:match('[^.]*$')
end

-- ---------------------------------------------------------------------------
-- History and scratch

function M.history()
  local entries, seen = {}, {}
  local ok, lines = pcall(vim.fn.readfile, history_path())
  for i = #(ok and lines or {}), 1, -1 do
    local good, h = pcall(vim.json.decode, lines[i])
    if good and type(h) == 'table' and not seen[h.sql] then
      seen[h.sql] = true
      entries[#entries + 1] = h
    end
    if #entries >= 500 then
      break
    end
  end
  if #entries == 0 then
    return notify('no history yet')
  end
  require('core.picker').pick({
    prompt = 'Hive history',
    items = entries,
    format = function(h)
      local outcome = h.error and 'failed' or h.rows and commas(h.rows) .. ' rows' or 'ok'
      return ('%s  %-10s %s'):format(os.date('%m-%d %H:%M', h.time), outcome, (h.sql:gsub('%s+', ' ')))
    end,
    preview = function(h)
      local lines = vim.split(h.sql, '\n')
      if h.error then
        vim.list_extend(lines, { '', '-- ' .. h.error:gsub('\n', '\n-- ') })
      end
      return { lines = vim.split(table.concat(lines, '\n'), '\n'), ft = 'sql' }
    end,
    -- Into this buffer if it is SQL, else the scratch buffer, below the cursor.
    on_choice = function(h)
      if vim.bo.filetype ~= 'sql' or not vim.bo.modifiable then
        M.scratch()
      end
      local lnum = vim.fn.line('.')
      local lines = vim.split(h.sql, '\n')
      table.insert(lines, 1, '')
      vim.api.nvim_buf_set_lines(0, lnum, lnum, false, lines)
      vim.api.nvim_win_set_cursor(0, { lnum + 2, 0 })
    end,
  })
end

function M.scratch()
  vim.cmd.edit(vim.fn.fnameescape(vim.fs.joinpath(query_dir(), 'scratch.sql')))
end

-- ---------------------------------------------------------------------------
-- Setup

vim.filetype.add({ extension = { hql = 'sql' } })
-- ftplugin/sql.vim maps <C-c>... in insert mode for its own completion; not wanted.
vim.g.omni_sql_no_default_maps = 1

vim.api.nvim_create_autocmd('FileType', {
  pattern = 'sql',
  callback = function(ev)
    -- Scheduled: ftplugin/sql.vim runs after this and sets its own omnifunc.
    vim.schedule(function()
      if vim.api.nvim_buf_is_valid(ev.buf) then
        vim.bo[ev.buf].omnifunc = "v:lua.require'core.hive'.omnifunc"
        vim.b[ev.buf].kw_omni = true -- core.completion autotriggers <C-x><C-o>, `.` too
      end
    end)
  end,
})

vim.api.nvim_create_autocmd('VimLeavePre', {
  callback = function()
    M.disconnect(true)
  end,
})

local map = vim.keymap.set
map('n', '<leader>hr', M.run_cursor, { desc = '[H]ive: [R]un statement under cursor' })
map('x', '<leader>hr', function()
  local l1, l2 = vim.fn.line('v'), vim.fn.line('.')
  vim.api.nvim_feedkeys(vim.keycode('<Esc>'), 'nx', false)
  M.run_lines(math.min(l1, l2), math.max(l1, l2))
end, { desc = '[H]ive: [R]un selected statements' })
map('n', '<leader>hc', M.cancel, { desc = '[H]ive: [C]ancel query' })
map('n', '<leader>hu', M.workspace, { desc = '[H]ive: workspace [U]I (browser, editor, results)' })
map('n', '<leader>hb', M.browser, { desc = '[H]ive: schema [B]rowser' })
for n, name in ipairs({ 'browser', 'editor', 'results' }) do
  map('n', '<leader>' .. n, function()
    M.focus(n)
  end, { desc = 'Hive: go to the ' .. name .. ' pane' })
end
map('n', '<leader>hh', M.history, { desc = '[H]ive: query [H]istory' })
map('n', '<leader>ho', M.show, { desc = '[H]ive: [O]pen results' })
map('n', '<leader>hs', M.scratch, { desc = '[H]ive: [S]cratch buffer' })

local cmd = vim.api.nvim_create_user_command
cmd('Hive', M.workspace, { desc = 'Toggle the Hive workspace tab' })
cmd('HiveConnect', M.connect, { desc = 'Connect to Hive (re-reads vim.g.hive)' })
cmd('HiveDisconnect', function()
  M.disconnect()
end, { desc = 'Close the Hive connections' })
cmd('HiveRun', function(o)
  if o.range > 0 then
    M.run_lines(o.line1, o.line2)
  else
    M.run_cursor()
  end
end, { range = true, desc = 'Run the statement under the cursor, or the range' })
cmd('HiveCancel', M.cancel, { desc = 'Cancel the running Hive query' })
cmd('HiveBrowser', M.browser, { desc = 'Toggle the Hive schema browser' })
cmd('HiveHistory', M.history, { desc = 'Hive query history' })
cmd('HiveRefresh', M.refresh, { desc = 'Forget cached Hive schema' })
cmd('HiveLog', function()
  vim.cmd('botright new')
  vim.bo.buftype, vim.bo.bufhidden = 'nofile', 'wipe'
  vim.api.nvim_buf_set_lines(0, 0, -1, false, S.stderr)
end, { desc = "The Hive helper's stderr" })

-- ---------------------------------------------------------------------------
-- The helper, written to stdpath('cache') and run with the environment's python.
-- JSON lines in both directions. The first line in is the connection config, then:
--
--   nvim -> helper  {op = query, id, lane, stmts, limit} | {op = export, id, stmts, path}
--                   {op = ping, id, lane} | {op = cancel}
--   helper -> nvim  {ev = result, id, columns, rows, truncated} | {ev = exported, id, path,
--                   rows} | {ev = error, id, msg} | {ev = log, id, line}
--                   {ev = connected, lane, driver}
--
-- Each lane (query, meta) is a thread with its own connection, made on first use.
-- Queries run asynchronously on the server and are polled, so cancel can reach them.

BRIDGE = [==[
import csv
import json
import os
import queue
import re
import shutil
import signal
import subprocess
import sys
import threading
import time

CFG = {}
_out = threading.Lock()


def emit(**ev):
    # ensure_ascii keeps the pipe pure ASCII, whatever the console codepage is.
    data = json.dumps(ev).encode("ascii") + b"\n"
    with _out:
        try:
            sys.stdout.buffer.write(data)
            sys.stdout.buffer.flush()
        except OSError:
            pass  # Neovim is gone


class Cancelled(Exception):
    pass


def message(e):
    # PyHive buries the server's message in the thrift response it raises with.
    for a in getattr(e, "args", ()):
        msg = getattr(getattr(a, "status", None), "errorMessage", None)
        if msg:
            return msg
    if type(e) in (RuntimeError, Dead):  # ours, already worded for people
        return str(e)
    return "%s: %s" % (type(e).__name__, e)


def cell(v):
    if v is None or isinstance(v, str):
        return v
    if isinstance(v, bytes):
        return v.decode("utf-8", "replace")
    return str(v)


def pure_sasl_shim():
    # PyHive 0.6 imports `sasl`, the C binding to libsasl2, which conda rarely has.
    # Stand in for it with pure-sasl, as PyHive 0.7 does: the same Client API that PyHive
    # and thrift_sasl call, on top of puresasl.client.SASLClient.
    import struct
    import types
    from puresasl.client import SASLClient

    class Client:
        def __init__(self):
            self.attrs, self.client, self.error = {}, None, None

        def setAttr(self, key, value):
            self.attrs[key] = value
            return True

        def init(self):
            return True

        def attempt(self, f, *args):
            try:
                return True, f(*args)
            except Exception as e:
                self.error = "%s: %s" % (type(e).__name__, e)
                return False, None

        def start(self, mech):
            a = self.attrs
            props = {"username": a.get("username"), "password": a.get("password")} if mech == "PLAIN" else {}
            ok, self.client = self.attempt(lambda: SASLClient(a.get("host"), a.get("service"), mechanism=mech, **props))
            if not ok:
                return False, mech, None
            ok, out = self.attempt(self.client.process)
            return ok, mech, out

        def step(self, challenge):
            return self.attempt(self.client.process, challenge)

        # libsasl2 puts a length header on wrapped data and expects it back on unwrap;
        # pure-sasl does neither. With QOP auth, Hive's default, nothing is wrapped.
        def encode(self, data):
            ok, out = self.attempt(self.client.wrap, data)
            if ok and out != data:
                out = struct.pack(">I", len(out)) + out
            return ok, out

        def decode(self, data):
            return self.attempt(self.client.unwrap, data[4:])

        def getError(self):
            return self.error

    sys.modules["sasl"] = types.SimpleNamespace(Client=Client)


# --- beeline: for clusters PyHive can't reach (ZooKeeper discovery, HTTP transport, SSL,
# Kerberos over SPNEGO). One long-lived beeline per lane, fed statements on stdin.
#
# `-f /dev/stdin` with --silent prints no prompt and no echo: each statement's output is a
# blank line, then (for a result set) a header and rows as tsv2, NULL as `NULL`. Errors
# go to stderr as `Error: ...`. Each statement is followed by a sentinel SELECT; its
# output marks where the statement's ends. Behaviour checked against beeline 2.3:
#   * SIGINT while a query executes cancels it server-side and beeline carries on;
#     SIGINT while rows stream wedges beeline, and SIGINT while idle kills it.
#   * a tab in the input triggers jline's completion, so tabs are sent as spaces.

SENTINEL = "nvim_sentinel"
EMPTY = object()


class Dead(Exception):
    """The beeline process is gone or unusable; the lane starts a new one next time."""


def hive_uri(cfg):
    """The JDBC URL: vim.g.hive.uri, else $HIVE_URI, else built from hive-site.xml."""
    uri = cfg.get("uri") or os.environ.get("HIVE_URI")
    if uri:
        return uri
    import xml.etree.ElementTree as ET
    dirs = [os.environ.get("HIVE_CONF_DIR"), os.environ.get("SPARK_CONF_DIR")]
    dirs += [os.path.join(os.environ[v], "conf") for v in ("SPARK_HOME", "HIVE_HOME") if os.environ.get(v)]
    paths = [cfg.get("hive_site")] + [os.path.join(d, "hive-site.xml") for d in dirs if d]
    path = next((p for p in paths if p and os.path.isfile(p)), None)
    if not path:
        raise RuntimeError("no JDBC URL: set vim.g.hive.uri, $HIVE_URI, or vim.g.hive.hive_site")
    props = {}
    for p in ET.parse(path).getroot().iter("property"):
        props[(p.findtext("name") or "").strip()] = (p.findtext("value") or "").strip()

    def get(key, default=""):
        return props.get(key) or default

    http = get("hive.server2.transport.mode").lower() == "http"
    params = []
    if get("hive.server2.support.dynamic.service.discovery").lower() == "true":
        zport = get("hive.zookeeper.client.port", "2181")
        hosts = [h.strip() for h in get("hive.zookeeper.quorum").split(",") if h.strip()]
        where = ",".join(h if ":" in h else h + ":" + zport for h in hosts)
        params += ["serviceDiscoveryMode=zooKeeper",
                   "zooKeeperNamespace=" + get("hive.server2.zookeeper.namespace", "hiveserver2")]
    else:
        host = cfg.get("host") or get("hive.server2.thrift.bind.host", "localhost")
        port = cfg.get("port") or get("hive.server2.thrift.http.port" if http else "hive.server2.thrift.port",
                                      "10001" if http else "10000")
        where = "%s:%s" % (host, port)
    if http:
        params += ["transportMode=http", "httpPath=" + get("hive.server2.thrift.http.path", "cliservice")]
    if get("hive.server2.use.SSL").lower() == "true":
        params.append("ssl=true")
    if get("hive.server2.authentication").upper() == "KERBEROS":
        params.append("principal=" + get("hive.server2.authentication.kerberos.principal"))
    return "jdbc:hive2://%s/%s;%s" % (where, cfg.get("database") or "default", ";".join(params))


def beeline_path(cfg):
    homes = [os.path.join(os.environ[v], "bin", "beeline") for v in ("SPARK_HOME", "HIVE_HOME") if os.environ.get(v)]
    for p in [cfg.get("beeline"), shutil.which("beeline")] + homes:
        if p and os.access(p, os.X_OK):
            return p
    raise RuntimeError("beeline not found on PATH, $SPARK_HOME/bin or $HIVE_HOME/bin: set vim.g.hive.beeline")


def beeline_error(lines):
    """The `Error: ...` messages in beeline's stderr, without the Java stack traces."""
    out, on = [], False
    for line in lines:
        s = line.rstrip()
        if s.startswith("Error:"):
            on = True
            s = s[6:].strip()
        elif not on:
            continue
        elif not s or s.lstrip().startswith(("at ", "...", "Caused by", "Suppressed")):
            on = False
            continue
        s = re.sub(r"\s*\(state=[^)]*\)$", "", s).replace("org.apache.hive.service.cli.HiveSQLException: ", "")
        out.append(s)
    msg = "\n".join(out)
    if re.search(r"GSS|Kerberos|kinit|TGT", msg, re.I):
        msg += "\n(no valid Kerberos ticket? run kinit, check with klist)"
    return msg


def limited(sql, n):
    """Cap a SELECT at n rows. Rows stream out of beeline slowly and can't be stopped."""
    if re.match(r"(?is)\s*(select|with)\b", sql) and not re.search(r"(?is)\binsert\b|\blimit\s+\d+\s*$", sql):
        return "%s LIMIT %d" % (sql, n)
    return sql


class Beeline:
    def __init__(self, cfg):
        cmd = [beeline_path(cfg), "-u", hive_uri(cfg), "--silent=true", "--showHeader=true",
               "--outputformat=tsv2", "--force=true", "--verbose=false", "--showWarnings=false"]
        if cfg.get("username"):
            cmd += ["-n", cfg["username"]]
        if cfg.get("password"):
            cmd += ["-p", cfg["password"]]
        cmd += list(cfg.get("beeline_args") or []) + ["-f", "/dev/stdin"]
        # Its own process group: SIGINT goes to beeline (and its wrapper scripts), not to us.
        self.p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE, start_new_session=True)
        self.out, self.err, self.n, self.dead = queue.Queue(), queue.Queue(), 0, False
        for stream, q in ((self.p.stdout, self.out), (self.p.stderr, self.err)):
            threading.Thread(target=self.pump, args=(stream, q), daemon=True).start()
        try:
            self.run("SELECT 1", timeout=int(cfg.get("connect_timeout") or 180))
        except Exception:
            self.close()
            raise

    @staticmethod
    def pump(stream, q):
        for raw in stream:
            q.put(raw.decode("utf-8", "replace").rstrip("\r\n"))
        q.put(None)

    def kill(self):
        self.dead = True
        try:
            os.killpg(self.p.pid, signal.SIGKILL)
        except OSError:
            pass

    def close(self):
        try:
            self.p.stdin.close()  # EOF: beeline closes its session and exits
            self.p.wait(timeout=5)
        except Exception:
            self.kill()

    def run(self, sql, lane=None, req=None, sink=None, timeout=None):
        """Run one statement. Returns (columns, rows), or (columns, row count) when
        `sink(row)` takes the rows instead -- it gets the column names first. columns is
        None when there is no result set."""
        self.n += 1
        mark = "NVIM_DONE_%d" % self.n
        errs = []
        while not self.err.empty():
            self.err.get_nowait()
        line = re.sub(r"[\t\r\n]", " ", sql)
        try:
            self.p.stdin.write(("%s;\nSELECT '%s' AS %s;\n" % (line, mark, SENTINEL)).encode("utf-8"))
            self.p.stdin.flush()
        except OSError:
            self.dead = True
            raise Dead("beeline is not running\n" + beeline_error(errs))
        # Output lines are handled three behind: the last three are the sentinel's.
        held, seen, columns, rows, count = [], 0, None, [], 0
        started, interrupted, last = time.time(), None, time.time()
        while True:
            try:
                l = self.out.get(timeout=0.1)
            except queue.Empty:
                l = EMPTY
            while not self.err.empty():
                e = self.err.get_nowait()
                if e is None:
                    continue
                errs.append(e)
                if "No current connection" in e:
                    self.kill()
                    raise Dead(beeline_error(errs) or "beeline could not connect:\n" + "\n".join(errs[-8:]))
                if lane and e.startswith("INFO"):
                    emit(ev="log", id=req["id"], line=e[:200])
            if l is None:
                self.dead = True
                time.sleep(0.2)
                while not self.err.empty():
                    errs.append(self.err.get_nowait() or "")
                raise Dead(beeline_error(errs) or "beeline exited:\n" + "\n".join(errs[-8:]))
            now = time.time()
            if l is EMPTY:
                if timeout and now - started > timeout:
                    self.kill()
                    raise Dead("no answer from beeline in %ds:\n%s" % (timeout, "\n".join(errs[-8:])))
                if interrupted and now - last > 30:
                    self.kill()  # the cancel landed between execution and fetching
                    raise Cancelled()
            else:
                seen, last = seen + 1, now
                held.append(l)
            if lane and lane.cancelled == req["id"] and not interrupted:
                if seen <= 1:  # only the statement's blank line so far: still executing
                    interrupted = now
                    os.killpg(self.p.pid, signal.SIGINT)
                elif sink:  # streaming an export: no safe way to stop beeline but this
                    self.kill()
                    raise Cancelled()
            done = len(held) >= 2 and held[-1] == mark and held[-2] == SENTINEL
            while len(held) > 3:
                l = held.pop(0)
                if seen - len(held) == 1 and l == "":
                    continue  # the statement's own blank line
                # Unquoted (beeline's disable.quoting.for.sv defaults to true), so a value
                # holding a tab or newline can't be told apart; Hive data rarely does.
                values = l.split("\t")
                if columns is None:
                    columns = values
                    if sink:
                        sink(columns)
                    continue
                row = [None if v == "NULL" else v for v in values]
                count += 1
                if sink:
                    sink(row)
                    if count % 10000 == 0:
                        emit(ev="log", id=req["id"], line="%d rows" % count)
                else:
                    rows.append(row)
            if done:
                break
        time.sleep(0.1)  # stderr from before the sentinel may still be in the pipe
        while not self.err.empty():
            errs.append(self.err.get_nowait() or "")
        msg = beeline_error(errs)
        if interrupted or "cancelled" in msg.lower() and lane and lane.cancelled == req["id"]:
            raise Cancelled()
        if msg:
            raise RuntimeError(msg)
        return columns, count if sink else rows


def connect():
    cfg = CFG
    driver = cfg.get("driver")
    if driver == "beeline" or (driver is None and not cfg.get("host")):
        return "beeline", Beeline(cfg)
    auth = (cfg.get("auth") or "NONE").upper()
    port = int(cfg.get("port") or 10000)
    db = cfg.get("database") or "default"
    if driver in (None, "pyhive"):
        try:
            import sasl  # noqa: F401
        except ImportError:
            try:
                pure_sasl_shim()
            except ImportError:
                pass  # no pure-sasl either: PyHive says what is missing
        try:
            from pyhive import hive
        except ImportError:
            if driver:
                raise
        else:
            kw = dict(host=cfg["host"], port=port, username=cfg.get("username"), database=db,
                      auth=auth, configuration=cfg.get("configuration") or None)
            if auth in ("LDAP", "CUSTOM"):
                kw["password"] = cfg.get("password")
            if auth == "KERBEROS":
                kw["kerberos_service_name"] = cfg.get("kerberos_service_name") or "hive"
            kw.update(cfg.get("kwargs") or {})
            return "pyhive", hive.connect(**kw)
    try:
        from impala.dbapi import connect as impyla_connect
    except ImportError:
        raise RuntimeError("neither pyhive nor impyla is installed for " + sys.executable)
    mech = {"NONE": "PLAIN", "CUSTOM": "PLAIN", "KERBEROS": "GSSAPI"}.get(auth, auth)
    kw = dict(host=cfg["host"], port=port, database=db, user=cfg.get("username"),
              password=cfg.get("password"), auth_mechanism=mech)
    if auth == "KERBEROS":
        kw["kerberos_service_name"] = cfg.get("kerberos_service_name") or "hive"
    kw.update(cfg.get("kwargs") or {})
    return "impyla", impyla_connect(**kw)


class Lane:
    def __init__(self, name):
        self.name = name
        self.q = queue.Queue()
        self.conn = self.kind = None
        self.current = self.cancelled = None
        self.thread = threading.Thread(target=self.loop, daemon=True)
        self.thread.start()

    def cancel(self):
        # Drop what is queued, then flag what is running; wait() acts on the flag.
        while True:
            try:
                req = self.q.get_nowait()
            except queue.Empty:
                break
            if req is None:
                self.q.put(None)
                break
            emit(ev="error", id=req["id"], msg="cancelled")
        self.cancelled = self.current

    def close(self):
        try:
            self.conn.close()
        except Exception:
            pass
        self.conn = None

    def loop(self):
        while True:
            req = self.q.get()
            if req is None:
                break
            self.current = req["id"]
            try:
                if self.conn is None:
                    self.kind, self.conn = connect()
                    emit(ev="connected", lane=self.name, driver=self.kind)
                getattr(self, req["op"])(req)
            except Cancelled:
                emit(ev="error", id=req["id"], msg="cancelled")
            except Exception as e:
                emit(ev="error", id=req["id"], msg=message(e))
                # A dropped connection is remade on the next request; SQL errors keep it.
                if isinstance(e, (OSError, EOFError, Dead)) or "Transport" in type(e).__name__:
                    self.close()
            finally:
                self.current = None
                if getattr(self.conn, "dead", False):
                    self.conn = None  # e.g. killed by cancel
        if self.conn is not None:
            self.close()

    def cursor(self):
        if self.kind == "impyla":
            return self.conn.cursor(configuration=CFG.get("configuration") or None)
        return self.conn.cursor()

    def wait(self, cur, req):
        for _ in range(5):
            if self.cancelled == req["id"]:
                try:
                    cur.cancel() if self.kind == "pyhive" else cur.cancel_operation()
                except Exception:
                    pass
                raise Cancelled()
            time.sleep(0.1)

    def execute(self, cur, sql, req):
        if self.cancelled == req["id"]:
            raise Cancelled()
        if self.kind == "impyla":
            cur.execute_async(sql)
            while cur.is_executing():
                self.wait(cur, req)
            return
        from TCLIService.ttypes import TOperationState as St
        busy = (St.INITIALIZED_STATE, St.PENDING_STATE, St.RUNNING_STATE)
        cur.execute(sql, async_=True)
        while True:
            status = cur.poll()
            if self.name == "query":
                self.log(cur, req)
            if status.operationState not in busy:
                break
            self.wait(cur, req)
        if status.operationState == St.CANCELED_STATE:
            raise Cancelled()
        if status.operationState == St.ERROR_STATE:
            raise RuntimeError(status.errorMessage or "query failed")

    def log(self, cur, req):
        # The last line of the server's log for this query: Tez / MapReduce progress.
        try:
            lines = [l.strip() for l in cur.fetch_logs() if l.strip()]
        except Exception:
            return
        if lines:
            emit(ev="log", id=req["id"], line=lines[-1][:200])

    def ping(self, req):
        emit(ev="result", id=req["id"], columns=[], rows=[], truncated=False)

    def query(self, req):
        if self.kind == "beeline":
            limit, columns, rows = req["limit"], None, []
            for sql in req["stmts"]:
                c, r = self.conn.run(limited(sql, limit + 1), self, req)
                if c is not None:
                    columns, rows = c, r
            emit(ev="result", id=req["id"], columns=columns or [], rows=rows[:limit],
                 truncated=len(rows) > limit)
            return
        cur = self.cursor()
        try:
            limit, desc, rows = req["limit"], None, []
            for sql in req["stmts"]:
                self.execute(cur, sql, req)
                if cur.description:
                    desc, rows = cur.description, cur.fetchmany(limit + 1)
            emit(ev="result", id=req["id"], columns=[d[0] for d in desc or []],
                 rows=[[cell(v) for v in r] for r in rows[:limit]], truncated=len(rows) > limit)
        finally:
            try:
                cur.close()
            except Exception:
                pass

    def export(self, req):
        if self.kind == "beeline":
            for sql in req["stmts"][:-1]:
                self.conn.run(sql, self, req)
            with open(req["path"], "w", newline="", encoding="utf-8") as f:
                columns, n = self.conn.run(req["stmts"][-1], self, req, sink=csv.writer(f).writerow)
            if columns is None:
                raise RuntimeError("the last statement returned no rows")
            emit(ev="exported", id=req["id"], path=req["path"], rows=n)
            return
        cur = self.cursor()
        try:
            for sql in req["stmts"]:
                self.execute(cur, sql, req)
            if not cur.description:
                raise RuntimeError("the last statement returned no rows")
            n = 0
            with open(req["path"], "w", newline="", encoding="utf-8") as f:
                w = csv.writer(f)
                w.writerow([d[0] for d in cur.description])
                while True:
                    if self.cancelled == req["id"]:
                        raise Cancelled()
                    rows = cur.fetchmany(10000)
                    if not rows:
                        break
                    w.writerows(rows)
                    n += len(rows)
                    emit(ev="log", id=req["id"], line="%d rows written" % n)
            emit(ev="exported", id=req["id"], path=req["path"], rows=n)
        finally:
            try:
                cur.close()
            except Exception:
                pass


def main():
    CFG.update(json.loads(sys.stdin.buffer.readline().decode("utf-8")))
    lanes = {"query": Lane("query"), "meta": Lane("meta")}
    # Bytes, decoded as UTF-8: on Windows sys.stdin would use the ANSI codepage.
    for raw in sys.stdin.buffer:
        try:
            cmd = json.loads(raw.decode("utf-8"))
        except ValueError:
            continue
        if cmd.get("op") == "cancel":
            lanes["query"].cancel()
        else:
            lanes[cmd.get("lane") or "query"].q.put(cmd)
    # Neovim went away: cancel what runs server-side, then close the connections.
    for lane in lanes.values():
        lane.cancel()
        lane.q.put(None)
    for lane in lanes.values():
        lane.thread.join(timeout=5)


if __name__ == "__main__":
    main()
]==]

return M
