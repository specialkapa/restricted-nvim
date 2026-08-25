-- Ruff format-on-save, restricted to the lines you actually changed.
--
--   * untracked file  -> format the whole file
--   * tracked file    -> format the whole file, but only APPLY the hunks that overlap
--                        lines you changed relative to the git index
--   * merge conflicts -> skipped
--   * not a git repo  -> skipped
--   * import sorting  -> NOT run here; use <leader>ri (ruff's organizeImports action)
--
-- Runs on BufWritePost rather than BufWritePre: the save itself never blocks, ruff and
-- git run just after, and the reformatted buffer is written back under a recursion
-- guard. That matters most on Windows, where each subprocess spawn costs 50-100ms.
--
-- No plugins: vim.fn.system, vim.diff and vim.api only.

local env = require 'core.lsp'

-- Drop the two --line-length args to let ruff honour pyproject.toml instead.
local LINE_LENGTH = '100'

-- result_type 'indices' yields hunks as {start_a, count_a, start_b, count_b}.
local diff_opts = { result_type = 'indices', algorithm = 'histogram', ignore_whitespace = false }

local writing = false -- guard so the write-back never re-enters this handler
local warned = false

---Run `git -C <dir> <args...>`, returning (stdout, exit_code).
local function git(dir, args)
  local cmd = { 'git', '-C', dir }
  vim.list_extend(cmd, args)
  local out = vim.fn.system(cmd)
  return out, vim.v.shell_error
end

---Untracked / unmerged state for a file, in one git call.
---Only the two-character XY status code is parsed -- never the path, so core.quotepath
---and spaces in filenames cannot break it.
local function vcs_info(bufname)
  local dir = vim.fn.fnamemodify(bufname, ':h')

  local out, code = git(dir, { 'status', '--porcelain', '-z', '--', bufname })
  if code ~= 0 then
    return nil, 'not a git repository'
  end

  local xy = out:sub(1, 2)
  local x, y = xy:sub(1, 1), xy:sub(2, 2)
  local has_conflicts = x == 'U' or y == 'U' or xy == 'AA' or xy == 'DD'

  -- Empty output means tracked and clean; '??' means untracked.
  return { dir = dir, is_tracked = xy ~= '??', has_conflicts = has_conflicts }, nil
end

---File contents as staged in the git index -- the baseline your edits are measured
---against. `:./name` resolves relative to the -C directory, so no path plumbing needed.
local function comparee_lines(dir, bufname)
  local rev = ':./' .. vim.fn.fnamemodify(bufname, ':t')
  local content, code = git(dir, { 'show', rev })
  if code ~= 0 then
    return nil, 'failed to read git index version'
  end

  -- git may hand back CRLF depending on core.autocrlf; buffer lines never carry \r, so
  -- strip it or every single line reads as modified.
  content = content:gsub('\r\n', '\n'):gsub('\n$', '')
  return vim.split(content, '\n', { plain = true }), nil
end

---Format `input` through ruff over stdin. Returns (output, err).
local function ruff_format(input, bufname)
  local exe = env.resolve 'ruff'
  if not exe then
    if not warned then
      warned = true
      vim.notify('ruff not found in the active environment or on PATH; formatting skipped', vim.log.levels.WARN)
    end
    return nil, 'ruff not found'
  end

  local output = vim.fn.system({
    exe,
    'format',
    '--line-length',
    LINE_LENGTH,
    '--stdin-filename',
    bufname == '' and 'stdin.py' or bufname,
    '-',
  }, input)
  if vim.v.shell_error ~= 0 then
    return nil, output
  end
  return output, nil
end

---Mutates the buffer in place; returns true if anything changed.
local function format_python(bufnr)
  local bufname = vim.api.nvim_buf_get_name(bufnr)
  if bufname == '' then
    return false
  end

  local info, info_err = vcs_info(bufname)
  if not info then
    vim.notify(info_err .. ', skipping modified-only formatting', vim.log.levels.WARN)
    return false
  end

  local buf_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local buf_content = table.concat(buf_lines, '\n')

  -- Untracked: no baseline to diff against, so format everything.
  if not info.is_tracked then
    local output, err = ruff_format(buf_content, bufname)
    if not output then
      if err ~= 'ruff not found' then
        vim.notify('ruff format failed: ' .. err, vim.log.levels.ERROR)
      end
      return false
    end
    if output == buf_content then
      return false
    end
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.split(output, '\n', { plain = true, trimempty = false }))
    return true
  end

  if info.has_conflicts then
    vim.notify('file has merge conflicts; skipping modified-only formatting', vim.log.levels.WARN)
    return false
  end

  local base_lines, base_err = comparee_lines(info.dir, bufname)
  if not base_lines then
    vim.notify('failed to resolve git base: ' .. base_err, vim.log.levels.ERROR)
    return false
  end
  local comparee_content = table.concat(base_lines, '\n')

  -- Lines the buffer changed vs the index -> the only ranges we may touch.
  local modifications = vim.diff(comparee_content, buf_content, diff_opts)
  if not modifications or vim.tbl_isempty(modifications) then
    return false
  end

  local allowed_ranges = {}
  for _, hunk in ipairs(modifications) do
    local new_start, new_count = hunk[3], hunk[4]
    if new_count > 0 then
      allowed_ranges[#allowed_ranges + 1] = { start_line = new_start, end_line = new_start + new_count - 1 }
    end
  end
  if vim.tbl_isempty(allowed_ranges) then
    return false
  end

  local formatted_output, fmt_err = ruff_format(buf_content, bufname)
  if not formatted_output then
    if fmt_err ~= 'ruff not found' then
      vim.notify('ruff format failed: ' .. fmt_err, vim.log.levels.ERROR)
    end
    return false
  end

  local formatted_lines = vim.split(formatted_output, '\n', { plain = true, trimempty = false })
  local formatted_content = table.concat(formatted_lines, '\n')

  local formatter_hunks = vim.diff(buf_content, formatted_content, diff_opts)
  if not formatter_hunks or vim.tbl_isempty(formatter_hunks) then
    return false
  end

  local function overlaps(range_start, range_count)
    local range_end = range_start + math.max(range_count, 1) - 1
    for _, allowed in ipairs(allowed_ranges) do
      if range_end >= allowed.start_line and range_start <= allowed.end_line then
        return true
      end
    end
    return false
  end

  -- Apply bottom-up so earlier edits do not shift the line numbers of later ones.
  table.sort(formatter_hunks, function(a, b)
    return a[1] > b[1]
  end)

  local changed = false
  for _, hunk in ipairs(formatter_hunks) do
    local old_start, old_count, new_start, new_count = hunk[1], hunk[2], hunk[3], hunk[4]
    if overlaps(old_start, old_count) then
      local replacement = {}
      for i = new_start, new_start + new_count - 1 do
        replacement[#replacement + 1] = formatted_lines[i] or ''
      end
      vim.api.nvim_buf_set_lines(bufnr, old_start - 1, old_start - 1 + old_count, false, replacement)
      changed = true
    end
  end

  return changed
end

---Write the buffer back after an async reformat. `noautocmd` stops this re-triggering us.
local function write_back(bufnr)
  if writing or not vim.api.nvim_buf_is_valid(bufnr) or not vim.bo[bufnr].modified then
    return
  end
  writing = true
  vim.api.nvim_buf_call(bufnr, function()
    vim.cmd 'silent! noautocmd write'
  end)
  writing = false
end

if vim.fn.executable 'git' == 0 then
  vim.notify('git not on PATH; python format-on-save disabled', vim.log.levels.WARN)
  return
end

vim.api.nvim_create_autocmd('BufWritePost', {
  group = vim.api.nvim_create_augroup('python-hunk-format', { clear = true }),
  pattern = '*.py',
  callback = function(args)
    local bufnr = args.buf
    vim.schedule(function()
      if writing or not vim.api.nvim_buf_is_valid(bufnr) then
        return
      end
      if format_python(bufnr) then
        write_back(bufnr)
      end
    end)
  end,
})
