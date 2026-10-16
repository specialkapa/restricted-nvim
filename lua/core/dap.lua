-- Python debugging over the Debug Adapter Protocol, no plugins.
--
-- A small DAP client: it starts debugpy's adapter (`python -m debugpy.adapter`) and
-- talks to it over stdio, which is all nvim-dap does for python. core.dapview draws the
-- panel (REPL, breakpoints, watches, scopes, exceptions, threads) like nvim-dap-view.
--
-- debugpy must be importable by the environment you debug, as ipdb was for pydebug:
--     conda install debugpy        (or: pip install debugpy)
--
-- Not reproduced: attaching to a running process, several sessions at once, other
-- languages, inline variable values (nvim-dap-virtual-text).

local uv = vim.uv or vim.loop

local M = {}

local BP_GROUP = 'dap-breakpoints'
local PC_GROUP = 'dap-pc'
local STORE = vim.fn.stdpath 'data' .. '/dap-breakpoints.json'
local ROOT_MARKERS = { 'pyproject.toml', 'setup.py', '.git' }
local WARN, ERROR = vim.log.levels.WARN, vim.log.levels.ERROR

-- Plain ASCII, like core.pydebug: renders without a patched Nerd Font.
vim.fn.sign_define('DapBreakpoint', { text = 'b', texthl = 'DiagnosticError' })
vim.fn.sign_define('DapBreakpointCondition', { text = 'B', texthl = 'DiagnosticWarn' })
vim.fn.sign_define('DapLogPoint', { text = 'L', texthl = 'DiagnosticInfo' })
vim.fn.sign_define('DapBreakpointRejected', { text = 'R', texthl = 'DiagnosticHint' })
vim.fn.sign_define('DapStopped', { text = '>', texthl = 'DiagnosticWarn', linehl = 'Visual' })

M.session = nil -- the running session, if any
M.last_config = nil -- for <leader>dR after the program has ended

-- debugpy's filters. A running adapter's own list replaces this.
M.exception_filters = {
  { filter = 'raised', label = 'Raised Exceptions' },
  { filter = 'uncaught', label = 'Uncaught Exceptions' },
  { filter = 'userUnhandled', label = 'User Uncaught Exceptions' },
}
M.exceptions_on = { uncaught = true }

-- core.dapview subscribes here and redraws on every change.
local listeners = {}
function M.on(fn)
  listeners[#listeners + 1] = fn
end
local function emit(event, data)
  for _, fn in ipairs(listeners) do
    local ok, err = pcall(fn, event, data)
    if not ok then
      vim.notify('dap listener: ' .. err, ERROR)
    end
  end
end

local function root()
  local found = vim.fs.find(ROOT_MARKERS, { upward = true, path = vim.fn.getcwd() })[1]
  return found and vim.fs.dirname(found) or vim.fn.getcwd()
end

local function buf_path(buf)
  if not vim.api.nvim_buf_is_valid(buf) or vim.bo[buf].buftype ~= '' then
    return nil
  end
  local name = vim.api.nvim_buf_get_name(buf)
  return name ~= '' and vim.fs.normalize(vim.fn.fnamemodify(name, ':p')) or nil
end

local function loaded_buf(path)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and buf_path(b) == path then
      return b
    end
  end
end

-- ---------------------------------------------------------------------------
-- Transport. Every DAP message is `Content-Length: N\r\n\r\n` + N bytes of JSON.
-- ---------------------------------------------------------------------------

local events, reverse = {}, {}

local function send(s, msg)
  s.seq = s.seq + 1
  msg.seq = s.seq
  local body = vim.json.encode(msg)
  s.stdin:write(('Content-Length: %d\r\n\r\n%s'):format(#body, body))
  return s.seq
end

---cb(err, body). `args` must not be an empty Lua table: vim.json encodes {} as [].
local function request(s, command, args, cb)
  if not s or s.closed then
    if cb then
      cb 'no debug session'
    end
    return
  end
  local seq = send(s, { type = 'request', command = command, arguments = args or vim.empty_dict() })
  s.callbacks[seq] = cb
    or function(err)
      if err then
        vim.notify(('dap %s: %s'):format(command, err), WARN)
      end
    end
end

local function dispatch(s, msg)
  if msg.type == 'response' then
    local cb = s.callbacks[msg.request_seq]
    s.callbacks[msg.request_seq] = nil
    if cb then
      local body = msg.body or {}
      local err = not msg.success and (msg.message or (body.error and body.error.format) or 'failed') or nil
      cb(err, body)
    end
  elseif msg.type == 'event' then
    if events[msg.event] then
      events[msg.event](s, msg.body or {})
    end
  elseif msg.type == 'request' then -- "reverse" requests, from the adapter to us
    if reverse[msg.command] then
      reverse[msg.command](s, msg)
    else
      send(s, { type = 'response', request_seq = msg.seq, command = msg.command, success = false, message = 'unsupported' })
    end
  end
end

local function reader(s)
  local pending = ''
  return function(err, chunk)
    if err or not chunk then
      return
    end
    pending = pending .. chunk
    while true do
      local sep = pending:find('\r\n\r\n', 1, true)
      if not sep then
        return
      end
      local len = tonumber(pending:sub(1, sep - 1):match 'Content%-Length:%s*(%d+)') or 0
      if #pending < sep + 3 + len then
        return
      end
      local body = pending:sub(sep + 4, sep + 3 + len)
      pending = pending:sub(sep + 4 + len)
      -- Read callbacks run in a fast context: no API calls until scheduled.
      vim.schedule(function()
        local ok, msg = pcall(vim.json.decode, body, { luanil = { object = true, array = true } })
        if ok and not s.closed then
          dispatch(s, msg)
        end
      end)
    end
  end
end

-- ---------------------------------------------------------------------------
-- Breakpoints. Signs move with your edits, so the placed sign is the truth for a
-- loaded buffer; the table is the truth for files that are not open. Persisted in
-- stdpath('data') like persistent-breakpoints.nvim did.
-- ---------------------------------------------------------------------------

local bps = {} -- [path] = { { line, condition?, logMessage?, verified?, sign? } }

local function load_store()
  if vim.fn.filereadable(STORE) == 0 then
    return
  end
  local ok, data = pcall(vim.json.decode, table.concat(vim.fn.readfile(STORE), '\n'), { luanil = { object = true } })
  if ok and type(data) == 'table' then
    for path, list in pairs(data) do
      bps[path] = list
    end
  end
end

---Pull current line numbers back from the signs.
local function sync(path)
  local buf, list = loaded_buf(path), bps[path]
  if not buf or not list then
    return
  end
  local placed = vim.fn.sign_getplaced(buf, { group = BP_GROUP })[1]
  local lnum_of = {}
  for _, sg in ipairs(placed and placed.signs or {}) do
    lnum_of[sg.id] = sg.lnum
  end
  local seen, kept = {}, {}
  for _, bp in ipairs(list) do
    bp.line = bp.sign and lnum_of[bp.sign] or bp.line
    if not seen[bp.line] then -- deleting lines can stack two signs on one line
      seen[bp.line] = true
      kept[#kept + 1] = bp
    end
  end
  bps[path] = kept
end

local function save()
  local out = {}
  for path, list in pairs(bps) do
    sync(path)
    if #list > 0 then
      out[path] = vim.tbl_map(function(bp)
        return { line = bp.line, condition = bp.condition, logMessage = bp.logMessage }
      end, bps[path])
    end
  end
  pcall(vim.fn.writefile, { vim.json.encode(out) }, STORE)
end

local function sign_name(bp)
  if bp.verified == false then
    return 'DapBreakpointRejected'
  end
  return bp.logMessage and 'DapLogPoint' or bp.condition and 'DapBreakpointCondition' or 'DapBreakpoint'
end

local function place_signs(buf)
  local path = buf_path(buf)
  if not path or not vim.api.nvim_buf_is_loaded(buf) then
    return
  end
  vim.fn.sign_unplace(BP_GROUP, { buffer = buf })
  local count = vim.api.nvim_buf_line_count(buf)
  for _, bp in ipairs(bps[path] or {}) do
    bp.line = math.min(bp.line, count)
    bp.sign = vim.fn.sign_place(0, BP_GROUP, sign_name(bp), buf, { lnum = bp.line, priority = 21 })
  end
end

local function send_breakpoints(s, path, cb)
  local list = bps[path] or {}
  local wanted = vim.tbl_map(function(bp)
    return { line = bp.line, condition = bp.condition, logMessage = bp.logMessage }
  end, list)
  if s and s.run_to and s.run_to.path == path then
    wanted[#wanted + 1] = { line = s.run_to.line }
  end
  request(s, 'setBreakpoints', { source = { path = path }, breakpoints = wanted }, function(err, body)
    if not err then
      for i, bp in ipairs(list) do
        local r = body.breakpoints and body.breakpoints[i]
        bp.verified = r and r.verified
      end
      local buf = loaded_buf(path)
      if buf then
        sync(path)
        place_signs(buf)
      end
      emit 'breakpoints'
    end
    if cb then
      cb()
    end
  end)
end

local function changed(path, buf)
  if buf then
    place_signs(buf)
  end
  save()
  if M.session then
    send_breakpoints(M.session, path)
  end
  emit 'breakpoints'
end

---opts: nil toggles a plain breakpoint; { condition = } or { logMessage = } sets one.
function M.toggle_breakpoint(opts)
  local buf = vim.api.nvim_get_current_buf()
  local path = buf_path(buf)
  if not path then
    return vim.notify('buffer has no file path', WARN)
  end
  sync(path)
  local line = vim.api.nvim_win_get_cursor(0)[1]
  local kept, existed = {}, false
  for _, bp in ipairs(bps[path] or {}) do
    if bp.line == line then
      existed = true
    else
      kept[#kept + 1] = bp
    end
  end
  if opts or not existed then
    kept[#kept + 1] = vim.tbl_extend('force', { line = line }, opts or {})
  end
  bps[path] = kept
  changed(path, buf)
end

function M.remove_breakpoint(path, line)
  sync(path)
  bps[path] = vim.tbl_filter(function(bp)
    return bp.line ~= line
  end, bps[path] or {})
  changed(path, loaded_buf(path))
end

function M.clear_breakpoints()
  local n = 0
  for path, list in pairs(bps) do
    n = n + #list
    bps[path] = {}
    changed(path, loaded_buf(path))
  end
  vim.notify(('removed %d breakpoint(s)'):format(n))
end

---Flat, sorted list: { path, line, condition?, logMessage?, verified? }.
function M.breakpoints()
  local out = {}
  for path, list in pairs(bps) do
    sync(path)
    for _, bp in ipairs(bps[path]) do
      out[#out + 1] = vim.tbl_extend('force', { path = path }, bp)
    end
  end
  table.sort(out, function(a, b)
    return a.path == b.path and a.line < b.line or a.path < b.path
  end)
  return out
end

local function send_exceptions(s, cb)
  local filters = {}
  for _, f in ipairs(M.exception_filters) do
    -- pytest catches every failure, so "uncaught" never fires in a test. userUnhandled
    -- stops where an exception leaves your code: the failing assert, not pytest.raises.
    if M.exceptions_on[f.filter] or (s.opts.test and f.filter == 'userUnhandled') then
      filters[#filters + 1] = f.filter
    end
  end
  request(s, 'setExceptionBreakpoints', { filters = filters }, function(err)
    if err then
      vim.notify('dap exceptions: ' .. err, WARN)
    end
    if cb then
      cb()
    end
  end)
end

function M.toggle_exception(filter)
  M.exceptions_on[filter] = not M.exceptions_on[filter] or nil
  if M.session then
    send_exceptions(M.session)
  end
  emit 'exceptions'
end

-- ---------------------------------------------------------------------------
-- Following execution
-- ---------------------------------------------------------------------------

local pc_buf = nil

local function clear_pc()
  if pc_buf and vim.api.nvim_buf_is_valid(pc_buf) then
    vim.fn.sign_unplace(PC_GROUP, { buffer = pc_buf })
  end
  pc_buf = nil
end

---A window showing an ordinary file: the current one, the previous one, or any.
local function editor_win()
  local function ok(w)
    return w ~= 0
      and vim.api.nvim_win_is_valid(w)
      and vim.api.nvim_win_get_config(w).relative == ''
      and vim.bo[vim.api.nvim_win_get_buf(w)].buftype == ''
  end
  local cur, prev = vim.api.nvim_get_current_win(), vim.fn.win_getid(vim.fn.winnr '#')
  if ok(cur) then
    return cur
  elseif ok(prev) then
    return prev
  end
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if ok(w) then
      return w
    end
  end
  vim.cmd 'topleft split'
  return vim.api.nvim_get_current_win()
end

local function show_frame(frame)
  clear_pc()
  local path = frame and frame.source and frame.source.path
  if not path or vim.fn.filereadable(path) == 0 then
    return
  end
  local win = editor_win()
  local buf = vim.fn.bufadd(path)
  vim.fn.bufload(buf)
  vim.bo[buf].buflisted = true
  if vim.api.nvim_win_get_buf(win) ~= buf then
    vim.api.nvim_win_set_buf(win, buf)
  end
  local lnum = math.max(1, math.min(frame.line, vim.api.nvim_buf_line_count(buf)))
  vim.api.nvim_set_current_win(win)
  vim.api.nvim_win_set_cursor(win, { lnum, math.max(0, (frame.column or 1) - 1) })
  if lnum < vim.fn.line 'w0' or lnum > vim.fn.line 'w$' then
    vim.cmd 'normal! zz'
  end
  pc_buf = buf
  vim.fn.sign_place(0, PC_GROUP, 'DapStopped', buf, { lnum = lnum, priority = 30 })
end

function M.select_frame(frame)
  local s = M.session
  if not s or not frame then
    return
  end
  s.frame, s.scopes = frame, nil
  show_frame(frame)
  emit 'frame'
  request(s, 'scopes', { frameId = frame.id }, function(err, body)
    if s.frame == frame then
      s.scopes = err and {} or body.scopes or {}
      emit 'scopes'
    end
  end)
end

local function resume(s)
  s.stopped, s.frame, s.frames, s.scopes, s.exception = false, nil, {}, nil, nil
  clear_pc()
  emit 'continued'
end

-- ---------------------------------------------------------------------------
-- Events and reverse requests
-- ---------------------------------------------------------------------------

events.initialized = function(s)
  -- Breakpoints and exception filters must all be in before configurationDone.
  local pending = 1
  local function done()
    pending = pending - 1
    if pending == 0 then
      request(s, 'configurationDone')
    end
  end
  for path, list in pairs(bps) do
    if #list > 0 then
      pending = pending + 1
      send_breakpoints(s, path, done)
    end
  end
  send_exceptions(s, done)
end

events.stopped = function(s, body)
  s.stopped, s.reason = true, body.reason
  s.thread_id = body.threadId or s.thread_id
  if s.run_to then -- drop the temporary run-to-cursor breakpoint
    local path = s.run_to.path
    s.run_to = nil
    send_breakpoints(s, path)
  end
  request(s, 'threads', nil, function(err, b)
    s.threads = not err and b.threads or {}
    emit 'threads'
  end)
  request(s, 'stackTrace', { threadId = s.thread_id, startFrame = 0, levels = 100 }, function(err, b)
    if err then
      return vim.notify('dap stackTrace: ' .. err, WARN)
    end
    s.frames = b.stackFrames or {}
    local top = s.frames[1]
    for _, f in ipairs(s.frames) do -- skip frames without a file, e.g. <string>
      if f.source and f.source.path and vim.fn.filereadable(f.source.path) == 1 then
        top = f
        break
      end
    end
    M.select_frame(top)
    emit('stopped', body)
  end)
  if body.reason == 'exception' then
    request(s, 'exceptionInfo', { threadId = s.thread_id }, function(err, b)
      if not err then
        s.exception = b
        emit('exception', b)
      end
    end)
  end
end

events.continued = function(s)
  if s.stopped then
    resume(s)
  end
end

events.output = function(_, body)
  if body.category ~= 'telemetry' then
    emit('output', body)
  end
end

-- pytest's exit codes, so a run that ends without stopping says why.
local PYTEST_EXIT = {
  [0] = 'all tests passed',
  [1] = 'tests failed',
  [2] = 'interrupted',
  [3] = 'internal error',
  [4] = 'usage error, see the terminal',
  [5] = 'no tests collected',
}

events.exited = function(s, body)
  local msg = ('process exited with code %s'):format(body.exitCode)
  if s.opts.test and PYTEST_EXIT[body.exitCode] then
    msg = msg .. ' (' .. PYTEST_EXIT[body.exitCode] .. ')'
  end
  emit('output', { category = 'console', output = msg .. '\n' })
  vim.notify('debug session ended: ' .. msg, body.exitCode == 0 and vim.log.levels.INFO or WARN)
end

local function close(s)
  if s.closed then
    return
  end
  s.closed = true
  clear_pc()
  pcall(function()
    s.stdin:close()
  end)
  -- debugpy exits once its client goes away; make sure it does.
  vim.defer_fn(function()
    if s.handle and not s.handle:is_closing() then
      pcall(s.handle.kill, s.handle, 'sigterm')
    end
  end, 1000)
  if M.session == s then
    M.session = nil
  end
  emit('end', s)
  if s.restart then
    M.start(s.config, s.opts)
  end
end

events.terminated = function(s)
  request(s, 'disconnect', { restart = false }, function()
    close(s)
  end)
end

reverse.runInTerminal = function(s, req)
  local a = req.arguments
  local env = nil
  for k, v in pairs(a.env or {}) do
    if type(v) == 'string' then
      env = env or {}
      env[k] = v
    end
  end
  local buf = vim.api.nvim_create_buf(false, true)
  local win = require('core.dapview').show_terminal(buf)
  local job = vim.api.nvim_win_call(win, function()
    return vim.fn.jobstart(a.args, { term = true, cwd = a.cwd, env = env })
  end)
  local resp = { type = 'response', request_seq = req.seq, command = req.command, success = job > 0 }
  if job > 0 then
    resp.body = { processId = vim.fn.jobpid(job) }
  else
    resp.message = 'could not start ' .. tostring(a.args[1])
  end
  send(s, resp)
end

-- ---------------------------------------------------------------------------
-- Starting and stopping
-- ---------------------------------------------------------------------------

---vim.g.dap_python overrides; then the active venv / conda env; then python on PATH.
---Self-contained on purpose: older copies of core.lsp do not export venv_python.
local function interpreter()
  if vim.g.dap_python then
    return vim.g.dap_python
  end
  for _, var in ipairs { 'VIRTUAL_ENV', 'CONDA_PREFIX' } do
    local env = vim.env[var]
    for _, name in ipairs { '/bin/python', '/bin/python3' } do
      if env and env ~= '' and vim.fn.executable(env .. name) == 1 then
        return env .. name
      end
    end
  end
  for _, name in ipairs { 'python', 'python3' } do
    if vim.fn.exepath(name) ~= '' then
      return vim.fn.exepath(name)
    end
  end
  return 'python'
end

local importable = {}
local function can_import(py, module)
  local key = py .. ':' .. module
  if importable[key] == nil then
    local ok, res = pcall(function()
      return vim.system({ py, '-c', 'import ' .. module }):wait()
    end)
    importable[key] = ok and res.code == 0
  end
  return importable[key]
end

---opts.test marks a pytest run (see send_exceptions).
function M.start(config, opts)
  if M.session then
    return vim.notify('a debug session is already running (<leader>dq stops it)', WARN)
  end
  local py = interpreter()
  if not can_import(py, 'debugpy') then
    return vim.notify(('debugpy is not importable by %s\nInstall it into that env: conda install debugpy'):format(py), ERROR)
  end

  local stdin, stdout, stderr = uv.new_pipe(false), uv.new_pipe(false), uv.new_pipe(false)
  local s = { seq = 0, callbacks = {}, capabilities = {}, threads = {}, frames = {}, config = config, stderr = '' }
  s.opts = opts or {}
  local handle
  handle = uv.spawn(py, { args = { '-m', 'debugpy.adapter' }, stdio = { stdin, stdout, stderr } }, function(code)
    handle:close()
    stdout:close()
    stderr:close()
    vim.schedule(function()
      if not s.closed and code ~= 0 then
        vim.notify(('debug adapter exited with %d\n%s'):format(code, s.stderr), ERROR)
      end
      close(s)
    end)
  end)
  if not handle then
    for _, p in ipairs { stdin, stdout, stderr } do
      p:close()
    end
    return vim.notify('could not start ' .. py, ERROR)
  end
  s.handle, s.stdin = handle, stdin
  stdout:read_start(reader(s))
  stderr:read_start(function(_, chunk)
    if chunk then
      s.stderr = s.stderr .. chunk
    end
  end)

  M.session, M.last_config, M.last_opts = s, config, s.opts
  emit('start', s)
  request(s, 'initialize', {
    clientID = 'neovim',
    clientName = 'Neovim',
    adapterID = 'debugpy',
    pathFormat = 'path',
    linesStartAt1 = true,
    columnsStartAt1 = true,
    supportsRunInTerminalRequest = true,
    supportsVariableType = true,
  }, function(err, caps)
    if err then
      vim.notify('dap initialize: ' .. err, ERROR)
      return close(s)
    end
    s.capabilities = caps
    M.exception_filters = caps.exceptionBreakpointFilters or M.exception_filters
    -- debugpy answers `launch` only after configurationDone, see events.initialized.
    request(s, 'launch', config, function(err2)
      if err2 then
        vim.notify('dap launch: ' .. err2, ERROR)
        close(s)
      end
    end)
  end)
end

---target: { program = file } or { module = 'pytest' }.
local function launch_config(name, target, args)
  return vim.tbl_extend('force', {
    name = name,
    type = 'python',
    request = 'launch',
    args = args or {},
    cwd = root(),
    console = 'integratedTerminal', -- runs in a terminal split, so input() works
    justMyCode = true,
    showReturnValue = true,
    -- init.lua points breakpoint() at ipdb; under debugpy it should stop here instead.
    env = { PYTHONBREAKPOINT = 'debugpy.breakpoint' },
  }, target)
end

---Debug the current file. From a non-python buffer, re-run the last program.
function M.start_file(args)
  local file = buf_path(vim.api.nvim_get_current_buf())
  if not file or vim.bo.filetype ~= 'python' then
    if M.last_config then
      return M.start(M.last_config, M.last_opts)
    end
    return vim.notify('open a python file to debug', WARN)
  end
  if vim.bo.modified then
    vim.cmd 'write'
  end
  M.start(launch_config(vim.fs.basename(file), { program = file }, args))
end

---Walk up from the cursor by indentation: the enclosing `def test_*`, and the
---`class Test*` around it. Returns e.g. { 'TestGroup', 'test_param' }, or nil.
local function test_at_cursor()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local lines = vim.api.nvim_buf_get_lines(0, 0, lnum, false)
  local parts, limit, found = {}, math.huge, false
  for i = lnum, 1, -1 do
    local line = lines[i]
    local indent, kind, name = line:match '^(%s*)async%s+(def)%s+([%w_]+)'
    if not indent then
      indent, kind, name = line:match '^(%s*)(%a+)%s+([%w_]+)'
    end
    if (kind == 'def' or kind == 'class') and #indent < limit then
      limit = #indent
      if kind == 'def' and not found and name:match '^test' then
        found = true
        table.insert(parts, 1, name)
      elseif kind == 'class' and found and name:match '^Test' then
        table.insert(parts, 1, name)
      end
      if limit == 0 then
        break
      end
    end
  end
  return found and parts or nil
end

---Debug pytest on the test under the cursor (scope 'test') or the whole file ('file').
---extra: more pytest arguments, e.g. { '-k', 'slow' }.
function M.start_test(scope, extra)
  local file = buf_path(vim.api.nvim_get_current_buf())
  if not file or vim.bo.filetype ~= 'python' then
    return vim.notify('open a python test file', WARN)
  end
  local py = interpreter()
  if not can_import(py, 'pytest') then
    return vim.notify(('pytest is not importable by %s\nInstall it into that env: conda install pytest'):format(py), vim.log.levels.ERROR)
  end
  local target, label = file, vim.fs.basename(file)
  if scope == 'test' then
    local parts = test_at_cursor()
    if not parts then
      return vim.notify('no test function around the cursor', WARN)
    end
    -- No parametrize id: a node id without one runs every parameter set.
    label = table.concat(parts, '::')
    target = file .. '::' .. label
  end
  if vim.bo.modified then
    vim.cmd 'write'
  end
  local args = vim.list_extend({ target }, extra or {})
  M.start(launch_config('pytest ' .. label, { module = 'pytest' }, args), { test = true })
end

function M.terminate()
  local s = M.session
  if not s then
    return
  end
  -- A second <leader>dq (or an adapter without `terminate`) kills the program outright.
  if s.terminating or not s.capabilities.supportsTerminateRequest then
    return request(s, 'disconnect', { terminateDebuggee = true }, function()
      close(s)
    end)
  end
  s.terminating = true
  request(s, 'terminate')
end

function M.restart()
  local s = M.session
  if s then
    s.restart = true
    return M.terminate()
  end
  if M.last_config then
    M.start(M.last_config, M.last_opts)
  end
end

-- ---------------------------------------------------------------------------
-- Stepping, evaluating
-- ---------------------------------------------------------------------------

local function stopped_session()
  local s = M.session
  if not s then
    vim.notify('no debug session', WARN)
  elseif not s.stopped then
    vim.notify 'the program is running'
  else
    return s
  end
end

local function step(command)
  return function()
    local s = stopped_session()
    if s then
      local tid = s.thread_id
      resume(s)
      request(s, command, { threadId = tid })
    end
  end
end

M.step_over, M.step_into, M.step_out = step 'next', step 'stepIn', step 'stepOut'
local do_continue = step 'continue'

function M.continue()
  if not M.session then
    return M.start_file()
  end
  do_continue()
end

function M.pause()
  local s = M.session
  if s and not s.stopped then
    request(s, 'pause', { threadId = s.thread_id or (s.threads[1] or {}).id or 1 })
  end
end

function M.run_to_cursor()
  local s = stopped_session()
  local path = buf_path(vim.api.nvim_get_current_buf())
  if s and path then
    s.run_to = { path = path, line = vim.api.nvim_win_get_cursor(0)[1] }
    send_breakpoints(s, path, do_continue)
  end
end

---cb(err, body) with body.result / body.type / body.variablesReference.
function M.evaluate(expr, context, cb)
  local s = M.session
  if not s then
    return cb 'no debug session'
  end
  request(s, 'evaluate', { expression = expr, context = context, frameId = s.frame and s.frame.id }, cb)
end

---cb(err, variables)
function M.variables(ref, cb)
  request(M.session, 'variables', { variablesReference = ref }, function(err, body)
    cb(err, not err and body.variables or {})
  end)
end

function M.set_variable(ref, name, value, cb)
  request(M.session, 'setVariable', { variablesReference = ref, name = name, value = value }, cb)
end

-- ---------------------------------------------------------------------------
-- Wiring
-- ---------------------------------------------------------------------------

local function browse_breakpoints()
  local items = M.breakpoints()
  if #items == 0 then
    return vim.notify 'no breakpoints set'
  end
  local picker = require 'core.picker'
  picker.pick {
    prompt = 'Breakpoints',
    items = items,
    format = function(i)
      local extra = i.logMessage and ('  [log: ' .. i.logMessage .. ']') or i.condition and ('  [' .. i.condition .. ']') or ''
      return ('%s:%d%s'):format(vim.fn.fnamemodify(i.path, ':.'), i.line, extra)
    end,
    preview = function(i)
      return picker.file_preview(i.path, i.line)
    end,
    on_choice = function(i, action)
      vim.cmd[action](vim.fn.fnameescape(i.path))
      pcall(vim.api.nvim_win_set_cursor, 0, { i.line, 0 })
      vim.cmd 'normal! zz'
    end,
  }
end

---Plain run in the terminal split; breakpoint() calls still stop, in ipdb.
local function run_file()
  local file = buf_path(vim.api.nvim_get_current_buf())
  if not file then
    return
  end
  if vim.bo.modified then
    vim.cmd 'write'
  end
  require('core.terminal').run(('%s %s'):format(interpreter(), vim.fn.fnameescape(file)), { height = 25 })
end

local function insert_breakpoint_call()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local line = vim.api.nvim_get_current_line()
  local indent = line:match '^(%s*)'
  if line:match ':%s*$' then
    indent = indent .. (vim.bo.expandtab and string.rep(' ', vim.fn.shiftwidth()) or '\t')
  end
  vim.api.nvim_buf_set_lines(0, lnum, lnum, false, { indent .. 'breakpoint()' })
end

load_store()

local group = vim.api.nvim_create_augroup('core-dap', { clear = true })
vim.api.nvim_create_autocmd('BufReadPost', {
  group = group,
  callback = function(args)
    if bps[buf_path(args.buf) or ''] then
      place_signs(args.buf)
    end
  end,
})
vim.api.nvim_create_autocmd('BufWritePost', {
  group = group,
  callback = function(args)
    local path = buf_path(args.buf)
    if path and bps[path] and #bps[path] > 0 then
      changed(path, nil)
    end
  end,
})
-- Neovim kills the program's terminal job on exit, but not the adapter.
vim.api.nvim_create_autocmd('VimLeavePre', {
  group = group,
  callback = function()
    local s = M.session
    if s and s.handle and not s.handle:is_closing() then
      pcall(s.handle.kill, s.handle, 'sigterm')
    end
  end,
})
-- This module is loaded on the first python buffer, after its BufReadPost.
for _, b in ipairs(vim.api.nvim_list_bufs()) do
  if vim.api.nvim_buf_is_loaded(b) and bps[buf_path(b) or ''] then
    place_signs(b)
  end
end

local view = function()
  return require 'core.dapview'
end
local map = vim.keymap.set
-- Same prefixes as core.pydebug: <leader>b* for breakpoints, <leader>d* for running.
-- Stepping keys follow pdb's commands where they can: n(ext), c(ontinue).
map('n', '<leader>ds', M.start_file, { desc = '[D]ebug: [S]tart under debugger' })
map('n', '<leader>dr', run_file, { desc = '[D]ebug: [R]un without the debugger' })
map('n', '<leader>dc', M.continue, { desc = '[D]ebug: [C]ontinue (or start)' })
map('n', '<leader>dn', M.step_over, { desc = '[D]ebug: [N]ext line (step over)' })
map('n', '<leader>di', M.step_into, { desc = '[D]ebug: Step [I]nto' })
map('n', '<leader>do', M.step_out, { desc = '[D]ebug: Step [O]ut' })
map('n', '<leader>df', function()
  M.start_test 'test'
end, { desc = '[D]ebug: test [F]unction under the cursor (pytest)' })
map('n', '<leader>dF', function()
  M.start_test 'file'
end, { desc = '[D]ebug: every test in the [F]ile (pytest)' })
map('n', '<leader>dt', M.run_to_cursor, { desc = '[D]ebug: Run [T]o cursor' })
map('n', '<leader>dp', M.pause, { desc = '[D]ebug: [P]ause' })
map('n', '<leader>dq', M.terminate, { desc = '[D]ebug: [Q]uit (twice kills)' })
map('n', '<leader>dR', M.restart, { desc = '[D]ebug: [R]estart' })
map('n', '<leader>dv', function()
  view().toggle()
end, { desc = '[D]ebug: Toggle the [V]iew panel' })
map('n', '<leader>b', function()
  M.toggle_breakpoint()
end, { desc = 'Debug: Toggle [B]reakpoint' })
map('n', '<leader>B', function()
  vim.ui.input({ prompt = 'Breakpoint condition: ' }, function(c)
    if c and c ~= '' then
      M.toggle_breakpoint { condition = c }
    end
  end)
end, { desc = 'Debug: Conditional [B]reakpoint' })
map('n', '<leader>bl', function()
  vim.ui.input({ prompt = 'Log message ({expr} is interpolated): ' }, function(m)
    if m and m ~= '' then
      M.toggle_breakpoint { logMessage = m }
    end
  end)
end, { desc = 'Debug: [L]og point' })
map('n', '<leader>bb', browse_breakpoints, { desc = 'Debug: [B]rowse [B]reakpoints' })
map('n', '<leader>bi', insert_breakpoint_call, { desc = 'Debug: [I]nsert breakpoint() call' })
map('n', '<leader>bc', M.clear_breakpoints, { desc = 'Debug: [C]lear all [B]reakpoints' })
map({ 'n', 'x' }, '<leader>dw', function()
  view().add_watch()
end, { desc = 'Debug: Add to [W]atch list' })
map('x', '<leader>ss', function()
  view().send_selection()
end, { desc = 'Debug: [S]end [S]election to REPL' })
map({ 'n', 'x' }, '<leader>?', function()
  view().hover()
end, { desc = 'Debug: Show value in float' })

vim.api.nvim_create_user_command('DapStart', function(o)
  M.start_file(o.fargs)
end, { nargs = '*', desc = 'Debug the current file, passing arguments' })
vim.api.nvim_create_user_command('DapTest', function(o)
  M.start_test(o.bang and 'file' or 'test', o.fargs)
end, { nargs = '*', bang = true, desc = 'Debug the test under the cursor (! = whole file), with pytest args' })
vim.api.nvim_create_user_command('DapPause', M.pause, { desc = 'Pause the running program' })
vim.api.nvim_create_user_command('DapTerminate', M.terminate, { desc = 'Stop debugging' })

return M
