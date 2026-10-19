-- Run the test nearest the cursor in the <leader>tt terminal, as `pytest -v -k <name>`.
--
--   <leader>nr   in a test file: the test under the cursor (or its whole class, from the
--                class header or between methods), limited to that file
--                anywhere else: every test whose name contains the function (or class)
--                under the cursor, across the project -- -k is a substring match, so
--                `compute_ecl` picks up test_compute_ecl, test_compute_ecl_stage_2, ...
--                Inside a nested helper it uses the outer function: tests are named
--                after that.
--
-- The command is typed into the terminal's shell, so it runs in whatever environment
-- that shell has activated, the output stays scrollable there, and <Up> re-runs it.

local M = {}

local function is_test_file(path)
  local name = vim.fs.basename(path)
  return name:match '^test_.*%.py$' ~= nil or name:match '_test%.py$' ~= nil
end

---The def/class blocks around `lnum`, innermost first: { { kind, name }, ... }. Found
---by indentation: walking up, each def or class indented less than everything seen so
---far encloses the cursor.
local function enclosing(lnum)
  local lines = vim.api.nvim_buf_get_lines(0, 0, lnum, false)
  local chain, limit = {}, math.huge
  for i = lnum, 1, -1 do
    local indent, rest = lines[i]:match '^(%s*)(.*)$'
    if rest ~= '' and rest:sub(1, 1) ~= '#' then
      local kind, name = rest:match '^(class)%s+([%w_]+)'
      if not kind then
        kind, name = rest:match '^(def)%s+([%w_]+)'
      end
      if not kind then
        kind, name = rest:match '^async%s+(def)%s+([%w_]+)'
      end
      -- On the def line itself, that def is the innermost block. Otherwise a block
      -- only encloses the cursor if it is indented less than the code at the cursor.
      if kind and (#indent < limit or i == lnum) then
        chain[#chain + 1] = { kind = kind, name = name }
        limit = #indent
      elseif i == lnum then
        limit = #indent
      end
      if limit == 0 then
        break
      end
    end
  end
  return chain
end

---`-k` expression and file argument for the code under the cursor, or nil.
local function selection(path, chain)
  if is_test_file(path) then
    -- Innermost test, plus each Test* class around it, outermost first.
    local parts = {}
    for i = #chain, 1, -1 do
      local b = chain[i]
      if (b.kind == 'class' and b.name:match '^Test') or (b.kind == 'def' and b.name:match '^test') then
        parts[#parts + 1] = b.name
      end
    end
    return #parts > 0 and table.concat(parts, ' and ') or nil, path
  end
  -- Source code: the outermost function (a method counts, its class does not), or
  -- the class when the cursor is in a class body outside any method.
  for i = #chain, 1, -1 do
    if chain[i].kind == 'def' then
      return chain[i].name, nil
    end
  end
  return chain[1] and chain[1].name, nil
end

local function project_root(path)
  return vim.fs.root(path, { 'pytest.ini', 'pyproject.toml', 'setup.cfg', 'tox.ini', 'setup.py', '.git' })
    or vim.fs.dirname(path)
end

function M.run_nearest()
  local path = vim.api.nvim_buf_get_name(0)
  if not path:match '%.py$' then
    vim.notify('pytest: not a python file', vim.log.levels.WARN)
    return
  end
  -- On a decorator, the def it decorates is the one meant.
  local lnum, last = vim.fn.line '.', vim.fn.line '$'
  while lnum < last and vim.fn.getline(lnum):match '^%s*@' do
    lnum = lnum + 1
  end
  local expr, file = selection(path, enclosing(lnum))
  if not expr then
    vim.notify('pytest: no test or function under the cursor', vim.log.levels.INFO)
    return
  end
  vim.cmd 'silent update' -- pytest reads the file from disk

  local root = project_root(path)
  local cmd = { 'python', '-m', 'pytest', '-v' }
  if file then
    -- Relative to the root, so the command stays short enough to read in the terminal.
    cmd[#cmd + 1] = vim.fn.shellescape(file:sub(1, #root + 1) == root .. '/' and file:sub(#root + 2) or file)
  end
  vim.list_extend(cmd, { '-k', vim.fn.shellescape(expr) })
  local line = table.concat(cmd, ' ')
  -- A subshell, so the terminal's own working directory is left where it was.
  if root ~= vim.fn.getcwd() then
    line = ('(cd %s && %s)'):format(vim.fn.shellescape(root), line)
  end
  require('core.terminal').run(line)
end

vim.keymap.set('n', '<leader>nr', M.run_nearest, { desc = 'Test: [R]un the nearest test in the terminal' })

return M
