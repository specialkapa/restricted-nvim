-- Git change signs in the sign column, gitsigns-style, with no plugin.
--
-- The buffer is diffed against the INDEX (what `git add` staged), like gitsigns:
--   +  added      ~  changed      _  deleted below this line      ‾  deleted above line 1
--
-- The index copy of the file is fetched with one async `git show :path` when the buffer
-- is read, written or re-entered. After that, every edit is re-diffed in-process with
-- vim.diff(), so the signs follow unsaved edits without a subprocess per keystroke.
--
--   ]h / [h       next / previous hunk (wraps with 'wrapscan')
--   ih            hunk text object (vih, dih, yih)
--   <leader>gp    preview the hunk under the cursor
--   <leader>ga    stage the hunk under the cursor (git apply --cached)
--   <leader>gr    reset the hunk to the index version (undo with u)
--   <leader>gA    stage the whole file (git add)
--   <leader>gR    reset the whole buffer to the index version
--   <leader>tg    toggle the signs
--
-- M.counts(buf) gives the +/~/- line counts for the statusline; a `User GitSignsUpdate`
-- autocmd fires whenever they may have changed.

local M = {}

local ns = vim.api.nvim_create_namespace 'user-gitsigns'
-- vim.diff was renamed vim.text.diff in 0.12; the old name still works in 0.11.
local diff = vim.text and vim.text.diff or vim.diff

-- Below diagnostics (10) so an error sign wins when both want the same line.
local PRIORITY = 6
local DEBOUNCE_MS = 100

local SIGNS = {
  add = { '+', 'GitSignsAdd' },
  change = { '~', 'GitSignsChange' },
  changedelete = { '~', 'GitSignsChange' },
  delete = { '_', 'GitSignsDelete' },
  topdelete = { '\u{203E}', 'GitSignsDelete' },
}

local enabled = true

---Per buffer: { file, root, rel, untracked, base, base_lines, base_eol, lines, hunks, timer }.
---Hunks are vim.diff 'indices' results: { old_start, old_count, new_start, new_count },
---old = index, new = buffer.
local cache = {}

local function notify_update(buf)
  vim.api.nvim_exec_autocmds('User', { pattern = 'GitSignsUpdate', modeline = false, data = { buf = buf } })
end

---First group that is actually defined: Added/Changed/Removed exist in the default
---colorscheme since 0.10, but older colorschemes only define the Diff* groups.
local function first_defined(...)
  for _, name in ipairs { ... } do
    if next(vim.api.nvim_get_hl(0, { name = name })) then
      return name
    end
  end
end

local function setup_highlight()
  local set = function(group, ...)
    vim.api.nvim_set_hl(0, group, { link = first_defined(...), default = true })
  end
  set('GitSignsAdd', 'Added', 'DiffAdd')
  set('GitSignsChange', 'Changed', 'DiffChange')
  set('GitSignsDelete', 'Removed', 'DiffDelete')
end

---Buffer contents as a string, so a clean buffer diffs as identical to the index. Only
---'eol' decides the final newline: it mirrors the file as read, while 'fixeol' would
---flag the last line of every file saved without one.
local function buf_text(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  if #lines == 1 and lines[1] == '' then
    return '', {}
  end
  local text = table.concat(lines, '\n')
  if vim.bo[buf].eol then
    text = text .. '\n'
  end
  return text, lines
end

---Buffer lines a hunk covers. A pure deletion covers no lines, so it is pinned to the
---line its sign is on: the one above the deleted lines, or line 1 for a delete at the top.
local function hunk_range(h)
  local start, count = h[3], h[4]
  if count == 0 then
    local l = math.max(start, 1)
    return l, l
  end
  return start, start + count - 1
end

local function place(buf)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  local c = cache[buf]
  if not enabled or not c or not c.hunks then
    return
  end
  local last = vim.api.nvim_buf_line_count(buf)
  local function sign(lnum, kind)
    if lnum >= 1 and lnum <= last then
      local s = SIGNS[kind]
      vim.api.nvim_buf_set_extmark(buf, ns, lnum - 1, 0, { sign_text = s[1], sign_hl_group = s[2], priority = PRIORITY })
    end
  end
  for _, h in ipairs(c.hunks) do
    local _, old_count, start, count = unpack(h)
    if count == 0 then
      sign(math.max(start, 1), start == 0 and 'topdelete' or 'delete')
    else
      for i = 0, count - 1 do
        local kind = i < old_count and 'change' or 'add'
        -- More lines removed than replaced: flag the last changed line, as gitsigns does.
        if old_count > count and i == count - 1 then
          kind = 'changedelete'
        end
        sign(start + i, kind)
      end
    end
  end
end

---Re-diff the buffer against the cached index text. Cheap enough to run on demand, so
---every action calls it first instead of trusting hunks from before a pending debounce.
local function compute(buf)
  local c = cache[buf]
  if not c or not c.base then
    return
  end
  local text, lines = buf_text(buf)
  local ok, hunks = pcall(diff, c.base, text, { result_type = 'indices', algorithm = 'histogram' })
  c.hunks, c.lines = ok and hunks or {}, lines
  place(buf)
  notify_update(buf)
end

local function detach(buf)
  local c = cache[buf]
  if c and c.timer then
    c.timer:close()
  end
  cache[buf] = nil
  if vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  end
  if c then
    notify_update(buf)
  end
end

---Store the index text for `buf` (in the main loop) and draw the signs.
local function set_base(buf, info, base, untracked)
  vim.schedule(function()
    -- The buffer may have been wiped or renamed while git ran.
    if not vim.api.nvim_buf_is_valid(buf) or vim.api.nvim_buf_get_name(buf) ~= info.file then
      return
    end
    local old = cache[buf]
    local base_lines = base == '' and {} or vim.split(base, '\n', { plain = true })
    local base_eol = base:sub(-1) == '\n'
    if base_eol then
      table.remove(base_lines)
    end
    cache[buf] = {
      file = info.file,
      root = info.root,
      rel = info.rel,
      untracked = untracked,
      base = base,
      base_lines = base_lines,
      base_eol = base_eol,
      timer = old and old.timer,
    }
    compute(buf)
  end)
end

---Fetch the index version of the buffer's file: rev-parse for the repo root and the
---path relative to it (prefix + basename, so symlinked checkouts still resolve), then
---`git show :path`. A file git does not track shows as all-added if it is untracked and
---not ignored; an ignored file, or one outside a repo, gets no signs.
local function attach(buf)
  local file = vim.api.nvim_buf_get_name(buf)
  if vim.bo[buf].buftype ~= '' or vim.bo[buf].binary or file == '' or vim.fn.filereadable(file) == 0 then
    return
  end
  local cmd = { 'git', '-C', vim.fs.dirname(file), 'rev-parse', '--show-toplevel', '--show-prefix' }
  vim.system(cmd, { text = true }, function(r)
    local root, prefix = r.stdout:match '^([^\n]*)\n([^\n]*)'
    if r.code ~= 0 or not root then
      vim.schedule(function()
        detach(buf)
      end)
      return
    end
    local info = { file = file, root = root, rel = prefix .. vim.fs.basename(file) }
    vim.system({ 'git', '-C', root, 'show', ':' .. info.rel }, { text = true }, function(s)
      if s.code == 0 then
        return set_base(buf, info, s.stdout, false)
      end
      local ls = { 'git', '-C', root, 'ls-files', '--others', '--exclude-standard', '--', info.rel }
      vim.system(ls, { text = true }, function(u)
        if u.code == 0 and vim.trim(u.stdout) ~= '' then
          set_base(buf, info, '', true)
        else
          vim.schedule(function()
            detach(buf)
          end)
        end
      end)
    end)
  end)
end

local function debounce(buf)
  local c = cache[buf]
  if not c then
    return
  end
  c.timer = c.timer or vim.uv.new_timer()
  c.timer:stop()
  c.timer:start(
    DEBOUNCE_MS,
    0,
    vim.schedule_wrap(function()
      if vim.api.nvim_buf_is_valid(buf) then
        compute(buf)
      end
    end)
  )
end

---Hunk under the cursor in the current buffer, after a fresh diff.
local function current_hunk()
  local buf = vim.api.nvim_get_current_buf()
  compute(buf)
  local c = cache[buf]
  if not c then
    vim.notify('not a git-tracked file', vim.log.levels.WARN)
    return
  end
  local lnum = vim.fn.line '.'
  for _, h in ipairs(c.hunks or {}) do
    local first, last = hunk_range(h)
    if lnum >= first and lnum <= last then
      return h, c, buf
    end
  end
  vim.notify('no hunk under the cursor', vim.log.levels.INFO)
end

---Re-fetch the index after git changed it, so staged hunks drop their signs.
local function git_then_refresh(buf, cmd, opts, done_msg)
  vim.system(cmd, opts or { text = true }, function(r)
    vim.schedule(function()
      if r.code ~= 0 then
        vim.notify(vim.trim(r.stderr ~= '' and r.stderr or 'git failed'), vim.log.levels.ERROR)
        return
      end
      vim.notify(done_msg)
      attach(buf)
    end)
  end)
end

---Lines added, changed and removed vs the index, counted the way gitsigns does: a hunk
---replacing 2 lines with 5 is 2 changed + 3 added. nil when git signs are not attached.
function M.counts(buf)
  local c = cache[buf == 0 and vim.api.nvim_get_current_buf() or buf]
  if not c or not c.hunks then
    return nil
  end
  local n = { added = 0, changed = 0, removed = 0 }
  for _, h in ipairs(c.hunks) do
    local old_count, count = h[2], h[4]
    local common = math.min(old_count, count)
    n.changed = n.changed + common
    n.added = n.added + count - common
    n.removed = n.removed + old_count - common
  end
  return n
end

function M.nav(dir)
  local buf = vim.api.nvim_get_current_buf()
  compute(buf)
  local hunks = cache[buf] and cache[buf].hunks or {}
  if #hunks == 0 then
    vim.notify('no hunks', vim.log.levels.INFO)
    return
  end
  local lnum, target = vim.fn.line '.', nil
  local from, to, step = 1, #hunks, 1
  if dir < 0 then
    from, to, step = #hunks, 1, -1
  end
  for i = from, to, step do
    local first = hunk_range(hunks[i])
    if (dir > 0 and first > lnum) or (dir < 0 and first < lnum) then
      target = first
      break
    end
  end
  if not target and vim.o.wrapscan then
    target = hunk_range(hunks[from])
  end
  if target then
    vim.cmd "normal! m'"
    vim.api.nvim_win_set_cursor(0, { target, 0 })
  end
end

function M.preview()
  local h, c = current_hunk()
  if not h then
    return
  end
  local old_start, old_count, start, count = unpack(h)
  local out = { ('@@ -%d,%d +%d,%d @@'):format(old_start, old_count, start, count) }
  for i = old_start, old_start + old_count - 1 do
    out[#out + 1] = '-' .. c.base_lines[i]
  end
  for i = start, start + count - 1 do
    out[#out + 1] = '+' .. c.lines[i]
  end
  vim.lsp.util.open_floating_preview(out, 'diff', { border = 'single', focus_id = 'user-gitsigns-preview' })
end

function M.reset_hunk()
  local h, c, buf = current_hunk()
  if not h then
    return
  end
  local old_start, old_count, start, count = unpack(h)
  local original = vim.list_slice(c.base_lines, old_start, old_start + old_count - 1)
  -- A pure deletion (count 0) puts the lines back after line `start`; anything else
  -- replaces the hunk's buffer lines.
  local first = count == 0 and start or start - 1
  vim.api.nvim_buf_set_lines(buf, first, first + count, false, original)
  compute(buf)
end

function M.reset_buffer()
  local buf = vim.api.nvim_get_current_buf()
  local c = cache[buf]
  if not c then
    vim.notify('not a git-tracked file', vim.log.levels.WARN)
    return
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, c.base_lines)
  compute(buf)
end

---Stage one hunk by feeding a zero-context patch to `git apply --cached`. The patch is
---built from the buffer, so unsaved edits can be staged too (as gitsigns does).
function M.stage_hunk()
  local h, c, buf = current_hunk()
  if not h then
    return
  end
  if c.untracked then
    vim.notify('untracked file: stage the whole file with <leader>gA', vim.log.levels.WARN)
    return
  end
  local old_start, old_count, start, count = unpack(h)
  -- New-side start as `git diff -U0` writes it, relative to the index: an insertion
  -- lands after old_start, a deletion leaves the file at old_start - 1.
  local new_start = old_count == 0 and old_start + 1 or count == 0 and old_start - 1 or old_start
  local p = {
    ('diff --git a/%s b/%s'):format(c.rel, c.rel),
    '--- a/' .. c.rel,
    '+++ b/' .. c.rel,
    ('@@ -%d,%d +%d,%d @@'):format(old_start, old_count, new_start, count),
  }
  local no_eol = '\\ No newline at end of file'
  for i = old_start, old_start + old_count - 1 do
    p[#p + 1] = '-' .. c.base_lines[i]
  end
  if old_count > 0 and not c.base_eol and old_start + old_count - 1 == #c.base_lines then
    p[#p + 1] = no_eol
  end
  for i = start, start + count - 1 do
    p[#p + 1] = '+' .. c.lines[i]
  end
  if count > 0 and not vim.bo[buf].eol and start + count - 1 == #c.lines then
    p[#p + 1] = no_eol
  end
  local cmd = { 'git', '-C', c.root, 'apply', '--cached', '--unidiff-zero', '-' }
  git_then_refresh(buf, cmd, { text = true, stdin = table.concat(p, '\n') .. '\n' }, 'hunk staged')
end

---`git add` stages the file on disk, so unsaved edits would be silently left out.
function M.stage_buffer()
  local buf = vim.api.nvim_get_current_buf()
  local c = cache[buf]
  if not c then
    vim.notify('not a git-tracked file', vim.log.levels.WARN)
    return
  end
  if vim.bo[buf].modified then
    vim.notify('buffer has unsaved edits: write it first', vim.log.levels.WARN)
    return
  end
  git_then_refresh(buf, { 'git', '-C', c.root, 'add', '--', c.rel }, nil, 'file staged')
end

function M.select_hunk()
  local h = current_hunk()
  if not h then
    return
  end
  local first, last = hunk_range(h)
  vim.cmd(('normal! %dGV%dG'):format(first, last))
end

function M.toggle()
  enabled = not enabled
  for buf in pairs(cache) do
    if vim.api.nvim_buf_is_valid(buf) then
      place(buf)
    end
  end
  vim.notify('Git signs ' .. (enabled and 'on' or 'off'))
end

setup_highlight()

local group = vim.api.nvim_create_augroup('user-gitsigns', { clear = true })
vim.api.nvim_create_autocmd('ColorScheme', { group = group, callback = setup_highlight })
-- BufEnter and FocusGained catch index changes made elsewhere (a commit in the terminal).
vim.api.nvim_create_autocmd({ 'BufReadPost', 'BufWritePost', 'BufEnter', 'FocusGained' }, {
  group = group,
  callback = function(args)
    attach(args.buf)
  end,
})
vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI' }, {
  group = group,
  callback = function(args)
    debounce(args.buf)
  end,
})
vim.api.nvim_create_autocmd('BufWipeout', {
  group = group,
  callback = function(args)
    detach(args.buf)
  end,
})

vim.keymap.set('n', ']h', function()
  M.nav(1)
end, { desc = 'Next git hunk' })
vim.keymap.set('n', '[h', function()
  M.nav(-1)
end, { desc = 'Previous git hunk' })
vim.keymap.set({ 'o', 'x' }, 'ih', M.select_hunk, { desc = 'Git hunk' })
vim.keymap.set('n', '<leader>gp', M.preview, { desc = '[G]it [P]review hunk' })
vim.keymap.set('n', '<leader>ga', M.stage_hunk, { desc = '[G]it [A]dd (stage) hunk' })
vim.keymap.set('n', '<leader>gr', M.reset_hunk, { desc = '[G]it [R]eset hunk' })
vim.keymap.set('n', '<leader>gA', M.stage_buffer, { desc = '[G]it [A]dd (stage) file' })
vim.keymap.set('n', '<leader>gR', M.reset_buffer, { desc = '[G]it [R]eset buffer' })
vim.keymap.set('n', '<leader>tg', M.toggle, { desc = '[T]oggle [G]it signs' })

return M
