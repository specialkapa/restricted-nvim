-- Update Python imports when a module or package is renamed or moved. No plugins.
--
--   :Rename {path}           move the current file to {path} (<leader>rf prompts for it)
--   R in netrw               netrw's rename, but moving a .py file or a package
--                            directory also updates the imports
--   :FixImports {old} {new}  after a `mv` / `git mv` done outside Neovim
--
-- Every .py file in the project is checked, and the edits are listed in a float first:
-- y applies them (and does the move), q / n / <Esc> cancels and touches nothing.
-- For pkg.old -> pkg.sub.new:
--
--   import pkg.old [as x]           -> import pkg.sub.new [as x]    (and pkg.old.f usages)
--   from pkg.old[.inner] import f   -> from pkg.sub.new[.inner] import f
--   from pkg import old [as x]      -> from pkg.sub import new [as x]  (and old.f usages)
--   'pkg.old.f' in a string         -> 'pkg.sub.new.f'   (mock.patch targets)
--
-- Relative imports that point at the moved module become absolute, and so do relative
-- imports inside the moved file(s) that would no longer resolve from the new place.
-- Module names count from the project root, or its src/ if the file is under it.
-- Open buffers are edited in place and saved (u undoes), the rest are rewritten on disk.

local M = {}

local MARKERS = { 'pyproject.toml', 'setup.py', 'setup.cfg', 'pytest.ini', 'tox.ini', '.git' }
-- Directories never searched when rg (which honours .gitignore) is not available.
local SKIP = { ['.git'] = true, ['.venv'] = true, venv = true, __pycache__ = true, node_modules = true,
  build = true, dist = true, ['.mypy_cache'] = true, ['.pytest_cache'] = true, ['.ruff_cache'] = true }

local function rel(path)
  return vim.fn.fnamemodify(path, ':.')
end

local function under(path, dir)
  return path == dir or path:sub(1, #dir + 1) == dir .. '/'
end

local function project_root(path)
  local dir = vim.fs.dirname(path)
  local root = vim.fs.root(dir, MARKERS) or dir
  return under(path, root .. '/src') and root .. '/src' or root
end

---Dotted module name of a .py file or package directory, or nil if it is not importable
---from `root` (outside it, or a path component that is not an identifier).
local function module_of(root, path)
  if not under(path, root) or path == root then
    return nil
  end
  local name = path:sub(#root + 2):gsub('%.py$', ''):gsub('/__init__$', '')
  if name:match '[^%w_/]' then
    return nil
  end
  return (name:gsub('/', '.'))
end

---The package a file's relative imports count from.
local function package_of(root, path)
  local mod = module_of(root, path)
  if not mod or vim.fs.basename(path) == '__init__.py' then
    return mod
  end
  return mod:match '^(.*)%.[^.]+$' or ''
end

---Absolute module for `from` (`..x.y` or `a.b`) as seen from package `pkg`.
local function resolve(pkg, from)
  local dots, rest = from:match '^(%.*)(.*)$'
  if dots == '' then
    return from
  end
  if not pkg then
    return nil
  end
  local parts = pkg == '' and {} or vim.split(pkg, '.', { plain = true })
  for _ = 2, #dots do -- one dot is the package itself
    if #parts == 0 then
      return nil
    end
    table.remove(parts)
  end
  if rest ~= '' then
    parts[#parts + 1] = rest
  end
  return table.concat(parts, '.')
end

---`name` after the move, or nil if the move does not affect it.
local function remap(name, old, new)
  if name == old then
    return new
  elseif name:sub(1, #old + 1) == old .. '.' then
    return new .. name:sub(#old + 1)
  end
end

---Replace whole-name occurrences of `from` in `line`. `left` and `right` test the
---characters on either side ('' at the line's ends).
local function sub_name(line, from, to, left, right)
  local out, pos, changed = {}, 1, false
  while true do
    local s, e = line:find(from, pos, true)
    if not s then
      break
    end
    if left(line:sub(s - 1, s - 1)) and right(line:sub(e + 1, e + 1)) then
      out[#out + 1] = line:sub(pos, s - 1) .. to
      changed = true
    else
      out[#out + 1] = line:sub(pos, e)
    end
    pos = e + 1
  end
  out[#out + 1] = line:sub(pos)
  return table.concat(out), changed
end

local function not_ident(c)
  return not c:match '[%w_.]'
end

-- ---------------------------------------------------------------------------
-- Import statements

---Import statements in `lines`, each { first, last, indent, kind = 'import'|'from',
---module, items = { { name, alias } }, comment, multiline }. A parenthesised `from`
---list may span lines; backslash continuations are not followed.
local function statements(lines)
  local out, i = {}, 1
  while i <= #lines do
    local indent, body = lines[i]:match '^(%s*)(.*)$'
    local comment = body:match '%s*(#.*)$'
    body = body:gsub('%s*#.*$', '')
    local s
    local mod, rest = body:match '^from%s+([%.%w_]+)%s+import%s+(.+)$'
    if mod then
      s = { first = i, last = i, indent = indent, kind = 'from', module = mod, comment = comment }
      local j = i
      if rest:match '^%(' then
        while not rest:find(')', 1, true) and j < #lines do
          j = j + 1
          rest = rest .. ',' .. lines[j]:gsub('%s*#.*$', '')
        end
      end
      s.last, s.multiline = j, j > i
      rest = rest:gsub('[()]', '')
    else
      rest = body:match '^import%s+(.+)$'
      if rest then
        s = { first = i, last = i, indent = indent, kind = 'import', comment = comment }
      end
    end
    if s then
      s.items = {}
      for item in vim.gsplit(rest, ',', { plain = true }) do
        local name, alias = vim.trim(item):match '^([%w_%.%*]+)%s+as%s+([%w_]+)$'
        name = name or vim.trim(item):match '^([%w_%.%*]+)$'
        if name then
          s.items[#s.items + 1] = { name = name, alias = alias }
        end
      end
      -- In a multi-line list, remember the line of each item that has one to itself, so
      -- an untouched item keeps its formatting and comment when the list is rewritten.
      for j = s.first + 1, s.last do
        local core = vim.trim((lines[j]:gsub('%s*#.*$', ''))):gsub(',$', '')
        for _, it in ipairs(s.items) do
          if core == it.name .. (it.alias and ' as ' .. it.alias or '') then
            it.line = lines[j]
          end
        end
      end
      out[#out + 1] = s
      i = s.last
    end
    i = i + 1
  end
  return out
end

local function render(s)
  local names = {}
  for _, it in ipairs(s.items) do
    names[#names + 1] = it.name .. (it.alias and ' as ' .. it.alias or '')
  end
  if s.kind == 'import' then
    return { s.indent .. 'import ' .. table.concat(names, ', ') .. (s.comment and '  ' .. s.comment or '') }
  end
  if s.multiline then
    local out = { s.indent .. 'from ' .. s.module .. ' import (' }
    for k, n in ipairs(names) do
      out[#out + 1] = s.items[k].line or s.indent .. '    ' .. n .. ','
    end
    out[#out + 1] = s.indent .. ')'
    return out
  end
  return { s.indent .. 'from ' .. s.module .. ' import ' .. table.concat(names, ', ') .. (s.comment and '  ' .. s.comment or '') }
end

---Rewrite one statement for the move. Returns the replacement lines, or nil if unchanged.
---`renames` collects names bound by the statement that change (old -> new), and
---`dotted` is set when a plain `import old...` means `old.x` usages need updating.
local function rewrite(s, f, old, new, renames, state)
  local changed, extra = false, {}
  if s.kind == 'import' then
    for _, it in ipairs(s.items) do
      local m = remap(it.name, old, new)
      if m then
        it.name, changed = m, true
        state.dotted = state.dotted or not it.alias
      end
    end
  else
    local abs = resolve(f.pkg_old, s.module)
    if not abs then
      return nil
    end
    local moved = remap(abs, old, new)
    if moved then
      s.module, changed = moved, true
    else
      if s.module:sub(1, 1) == '.' and f.moved and resolve(f.pkg_new, s.module) ~= abs then
        s.module, changed = abs, true -- this file moved, the target did not
      end
      local keep = {}
      for _, it in ipairs(s.items) do
        local full = abs == '' and it.name or abs .. '.' .. it.name
        if full == old then
          local parent, name = new:match '^(.*)%.([^.]+)$'
          parent, name = parent or '', name or new
          if not it.alias and name ~= it.name then
            renames[it.name] = name
          end
          changed = true
          if resolve(f.pkg_new, s.module) == parent then
            keep[#keep + 1] = { name = name, alias = it.alias }
          elseif parent == '' then
            extra[#extra + 1] = { kind = 'import', indent = s.indent, items = { { name = name, alias = it.alias } } }
          else
            extra[#extra + 1] = { kind = 'from', indent = s.indent, module = parent, items = { { name = name, alias = it.alias } } }
          end
        else
          keep[#keep + 1] = it
        end
      end
      s.items = keep
    end
  end
  if not changed then
    return nil
  end
  local out = #s.items > 0 and render(s) or {}
  for _, x in ipairs(extra) do
    vim.list_extend(out, render(x))
  end
  return out
end

-- ---------------------------------------------------------------------------
-- Finding the edits

---The loaded buffer for `path`, by exact name (bufnr() would take it as a pattern).
local function buf_of(path)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.api.nvim_buf_get_name(buf) == path then
      return buf
    end
  end
end

local function read(path)
  local buf = buf_of(path)
  if buf then
    return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  end
  return vim.fn.filereadable(path) == 1 and vim.fn.readfile(path) or nil
end

---Project .py files that could mention `needle`: rg's list when it is installed, else
---every .py file outside SKIP (each is read and checked anyway).
local function candidates(root, needle)
  if vim.fn.executable 'rg' == 1 then
    local out = vim.fn.systemlist { 'rg', '-l', '-F', '--type', 'py', '--', needle, root }
    if vim.v.shell_error <= 1 then
      return out
    end
  end
  local files = {}
  for name, kind in vim.fs.dir(root, { depth = 50, skip = function(dir)
    return not SKIP[vim.fs.basename(dir)]
  end }) do
    if kind == 'file' and name:match '%.py$' then
      files[#files + 1] = root .. '/' .. name
    end
  end
  return files
end

---Every edit the move `old_path` -> `new_path` (file or directory) calls for, as
---{ file = final path, first, last, before = lines, after = lines }. Works before the
---move (files are read from the old place) and after it (:FixImports).
local function plan(old_path, new_path)
  local root = project_root(new_path)
  local old, new = module_of(root, old_path), module_of(root, new_path)
  if not old or not new then
    return nil, ('not an importable module under %s'):format(rel(root))
  end
  if old == new then
    return {}, root
  end

  -- The moved files, old path -> final path.
  local moved = {}
  if old_path:match '%.py$' then
    moved[old_path] = new_path
  else
    local dir = vim.fn.isdirectory(new_path) == 1 and new_path or old_path
    for name, kind in vim.fs.dir(dir, { depth = 50 }) do
      if kind == 'file' and name:match '%.py$' then
        moved[old_path .. '/' .. name] = new_path .. '/' .. name
      end
    end
  end

  -- Files to check, keyed by final path, with the path their imports resolve from.
  local files = {}
  for o, n in pairs(moved) do
    files[n] = o
  end
  local needle = old:match '([^.]+)$'
  for _, path in ipairs(candidates(root, needle)) do
    -- A moved file found at its old place (before the move) is already listed.
    if not moved[path] then
      files[path] = files[path] or path
    end
  end

  local edits = {}
  for final, from in pairs(files) do
    local lines = read(vim.fn.filereadable(final) == 1 and final or from)
    if lines and table.concat(lines, '\n'):find(needle, 1, true) or (lines and from ~= final) then
      local f = { pkg_old = package_of(root, from), pkg_new = package_of(root, final), moved = from ~= final }
      local renames, state, in_import = {}, {}, {}
      for _, s in ipairs(statements(lines)) do
        for l = s.first, s.last do
          in_import[l] = true
        end
        local before = vim.list_slice(lines, s.first, s.last)
        local after = rewrite(s, f, old, new, renames, state)
        if after then
          edits[#edits + 1] = { file = final, first = s.first, last = s.last, before = before, after = after }
        end
      end
      -- Usages on other lines: dotted paths after a plain `import old`, renamed names
      -- bound by `from pkg import old`, and dotted paths quoted in strings.
      for l, line in ipairs(lines) do
        if not in_import[l] then
          local text, any = line, false
          local function apply(from_name, to_name, left, right)
            local changed
            text, changed = sub_name(text, from_name, to_name, left, right)
            any = any or changed
          end
          if state.dotted then
            apply(old, new, not_ident, function(c)
              return not c:match '[%w_]'
            end)
          end
          for a, b in pairs(renames) do
            apply(a .. '.', b .. '.', not_ident, function()
              return true
            end)
          end
          if old:find('.', 1, true) then
            apply(old, new, function(c)
              return c == "'" or c == '"'
            end, function(c)
              return c == '.' or c == "'" or c == '"'
            end)
          end
          if any then
            edits[#edits + 1] = { file = final, first = l, last = l, before = { line }, after = { text } }
          end
        end
      end
    end
  end
  table.sort(edits, function(a, b)
    return a.file < b.file or (a.file == b.file and a.first < b.first)
  end)
  return edits, root
end

-- ---------------------------------------------------------------------------
-- Moving and applying

---Move a file or directory, saving and renaming any buffers showing it. Returns ok, err.
local function move(old_path, new_path)
  if vim.uv.fs_stat(new_path) then
    return false, rel(new_path) .. ' already exists'
  end
  local bufs = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(buf)
    -- File buffers only: netrw's own buffer is named after the directory it shows.
    if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].buftype == '' and vim.bo[buf].filetype ~= 'netrw'
      and name ~= '' and under(name, old_path) then
      vim.api.nvim_buf_call(buf, function()
        vim.cmd 'silent update'
      end)
      bufs[buf] = new_path .. name:sub(#old_path + 1)
    end
  end
  vim.fn.mkdir(vim.fs.dirname(new_path), 'p')
  local ok, err = vim.uv.fs_rename(old_path, new_path)
  if not ok then
    return false, err
  end
  for buf, name in pairs(bufs) do
    local before = vim.api.nvim_buf_get_name(buf)
    vim.api.nvim_buf_set_name(buf, name)
    -- Same contents as the moved file: the write just ties the buffer to its new name.
    vim.api.nvim_buf_call(buf, function()
      vim.cmd 'silent! write!'
    end)
    -- set_name leaves the old name behind as an unlisted alternate buffer.
    local stale = buf_of(before) or vim.fn.bufnr(before)
    if stale ~= -1 and stale ~= buf and vim.api.nvim_buf_get_name(stale) == before then
      pcall(vim.api.nvim_buf_delete, stale, { force = true })
    end
  end
  return true
end

local function apply(edits)
  local by_file = {}
  for _, e in ipairs(edits) do
    by_file[e.file] = by_file[e.file] or {}
    table.insert(by_file[e.file], e)
  end
  for file, list in pairs(by_file) do
    -- Bottom up, so earlier line numbers stay valid.
    table.sort(list, function(a, b)
      return a.first > b.first
    end)
    local buf = buf_of(file)
    if buf then
      for _, e in ipairs(list) do
        vim.api.nvim_buf_set_lines(buf, e.first - 1, e.last, false, e.after)
      end
      vim.api.nvim_buf_call(buf, function()
        vim.cmd 'silent update'
      end)
      -- Flash the rewritten lines where they ended up: walk top-down, shifting each edit
      -- by how much the ones above it grew or shrank.
      local ranges, shift = {}, 0
      for i = #list, 1, -1 do
        local e = list[i]
        if #e.after > 0 then
          ranges[#ranges + 1] = { e.first + shift, e.first + shift + #e.after - 1 }
        end
        shift = shift + #e.after - (e.last - e.first + 1)
      end
      require('lib.fade').lines(buf, ranges)
    else
      local lines = vim.fn.readfile(file)
      for _, e in ipairs(list) do
        for _ = e.first, e.last do
          table.remove(lines, e.first)
        end
        for k, l in ipairs(e.after) do
          table.insert(lines, e.first + k - 1, l)
        end
      end
      vim.fn.writefile(lines, file)
    end
  end
end

---The preview: every edit as -/+ lines under its file, in a float you can scroll.
---y runs `on_yes`; q, n, <Esc> or leaving the float cancels.
local function confirm(title, edits, on_yes)
  local lines, file = {}, nil
  for _, e in ipairs(edits) do
    if e.file ~= file then
      file = e.file
      if #lines > 0 then
        lines[#lines + 1] = ''
      end
      lines[#lines + 1] = rel(file)
    end
    for k, l in ipairs(e.before) do
      lines[#lines + 1] = ('-%5d  %s'):format(e.first + k - 1, l)
    end
    for _, l in ipairs(e.after) do
      lines[#lines + 1] = ('+%5s  %s'):format('', l)
    end
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = 'diff'
  local width = vim.fn.strdisplaywidth(title) + 4
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l) + 1)
  end
  width = math.min(width, math.floor(vim.o.columns * 0.85))
  local height = math.min(#lines, math.floor((vim.o.lines - vim.o.cmdheight) * 0.8))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    row = math.floor((vim.o.lines - vim.o.cmdheight - height) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2),
    width = width,
    height = height,
    style = 'minimal',
    border = 'single',
    title = title,
    title_pos = 'center',
    footer = ' y apply · q cancel ',
    footer_pos = 'right',
  })
  vim.wo[win].wrap = false
  -- The editor's background rather than NormalFloat's (darker in e.g. catppuccin). The
  -- border, title and footer groups have no background of their own, so they take it too.
  vim.wo[win].winhighlight = 'NormalFloat:Normal,FloatBorder:WinSeparator,FloatTitle:Title,FloatFooter:Comment'
  local done = false
  local function close(yes)
    if done then
      return
    end
    done = true
    pcall(vim.api.nvim_win_close, win, true)
    if yes then
      on_yes()
    else
      vim.notify 'imports: cancelled, nothing changed'
    end
  end
  vim.keymap.set('n', 'y', function()
    close(true)
  end, { buffer = buf, nowait = true })
  for _, key in ipairs { 'q', 'n', '<Esc>' } do
    vim.keymap.set('n', key, function()
      close(false)
    end, { buffer = buf, nowait = true })
  end
  vim.api.nvim_create_autocmd('WinLeave', {
    buffer = buf,
    once = true,
    callback = function()
      vim.schedule(function()
        close(false)
      end)
    end,
  })
end

local function is_python(path)
  if path:match '%.py$' then
    return true
  end
  return vim.fn.isdirectory(path) == 1 and #vim.fn.globpath(path, '**/*.py', false, true) > 0
end

---Move `old_path` to `new_path`, updating imports after a preview. `after` runs once
---the move is done (to refresh netrw, say).
function M.move(old_path, new_path, after)
  old_path, new_path = old_path:gsub('/+$', ''), new_path:gsub('/+$', '')
  if old_path == new_path then
    return
  end
  local function go(edits)
    local ok, err = move(old_path, new_path)
    if not ok then
      vim.notify('imports: move failed: ' .. err, vim.log.levels.ERROR)
      return
    end
    if edits then
      apply(edits)
    end
    vim.notify(('moved %s -> %s%s'):format(rel(old_path), rel(new_path),
      edits and #edits > 0 and (', %d import edit(s)'):format(#edits) or ''))
    if after then
      after()
    end
  end
  if not is_python(old_path) then
    return go(nil)
  end
  local edits, err = plan(old_path, new_path)
  if not edits then
    vim.notify('imports: ' .. err .. ' -- moving without updating imports', vim.log.levels.WARN)
    return go(nil)
  end
  if #edits == 0 then
    return go(edits)
  end
  confirm((' move %s -> %s '):format(rel(old_path), rel(new_path)), edits, function()
    go(edits)
  end)
end

---After a move done elsewhere: same edits, nothing to move.
function M.fix(old_path, new_path)
  old_path, new_path = old_path:gsub('/+$', ''), new_path:gsub('/+$', '')
  local edits, err = plan(old_path, new_path)
  if not edits then
    vim.notify('imports: ' .. err, vim.log.levels.WARN)
  elseif #edits == 0 then
    vim.notify 'imports: nothing refers to the old module'
  else
    confirm((' imports %s -> %s '):format(rel(old_path), rel(new_path)), edits, function()
      apply(edits)
      vim.notify(('imports: %d edit(s) applied'):format(#edits))
    end)
  end
end

---Target for :Rename: a directory (existing, or written with a trailing /) keeps the
---file's name.
local function target(src, arg)
  local dest = vim.fn.fnamemodify(vim.fn.expand(arg), ':p')
  if arg:match '/$' or vim.fn.isdirectory(dest) == 1 then
    dest = dest:gsub('/+$', '') .. '/' .. vim.fs.basename(src)
  end
  return dest
end

function M.rename_current(arg)
  local src = vim.api.nvim_buf_get_name(0)
  if src == '' or vim.bo.buftype ~= '' then
    vim.notify('imports: this buffer is not a file', vim.log.levels.WARN)
    return
  end
  if not vim.uv.fs_stat(src) then
    vim.notify('imports: ' .. rel(src) .. ' is not on disk yet -- write it first', vim.log.levels.WARN)
    return
  end
  if arg and arg ~= '' then
    return M.move(src, target(src, arg))
  end
  vim.ui.input({ prompt = 'Move to: ', default = rel(src), completion = 'file' }, function(input)
    if input and input ~= '' then
      M.move(src, target(src, input))
    end
  end)
end

---netrw's R, routed through M.move. Marked files (mf) still go to netrw's own rename.
local function netrw_rename()
  local marked = vim.fn['netrw#Expose'] 'netrwmarkfilelist'
  if type(marked) == 'table' and #marked > 0 then
    return vim.fn['netrw#Call']('NetrwLocalRename', vim.b.netrw_curdir)
  end
  local word = vim.fn['netrw#Call'] 'NetrwGetWord'
  if word == '' or word == './' or word == '../' then
    return
  end
  -- The same path netrw's own rename works out for the entry under the cursor.
  local src = vim.fn['netrw#Call']('ComposePath', vim.b.netrw_curdir, word):gsub('/+$', '')
  local input = vim.fn.input('Move to: ', rel(src), 'file')
  if input == '' then
    return
  end
  local view = vim.fn.winsaveview()
  M.move(src, vim.fn.fnamemodify(input, ':p'), function()
    pcall(function()
      vim.fn['netrw#Call']('NetrwRefresh', 1, vim.fn['netrw#Call']('NetrwBrowseChgDir', 1, './', 0))
      vim.fn.winrestview(view)
    end)
  end)
end

vim.api.nvim_create_user_command('Rename', function(cmd)
  M.rename_current(cmd.args)
end, { nargs = '?', complete = 'file', desc = 'Move the current file and update Python imports' })
vim.api.nvim_create_user_command('FixImports', function(cmd)
  if #cmd.fargs ~= 2 then
    vim.notify('usage: :FixImports {old path} {new path}', vim.log.levels.WARN)
    return
  end
  M.fix(vim.fn.fnamemodify(cmd.fargs[1], ':p'), vim.fn.fnamemodify(cmd.fargs[2], ':p'))
end, { nargs = '+', complete = 'file', desc = 'Update Python imports after a file was moved' })
vim.keymap.set('n', '<leader>rf', M.rename_current, { desc = '[R]ename / move this [F]ile, updating imports' })

vim.api.nvim_create_autocmd('FileType', {
  group = vim.api.nvim_create_augroup('user-pyimports', { clear = true }),
  pattern = 'netrw',
  callback = function(args)
    vim.keymap.set('n', 'R', netrw_rename, { buffer = args.buf, nowait = true, desc = 'Rename / move, updating Python imports' })
  end,
})

return M
