-- Markdown prose reflow, in pure Lua.
--
-- Stands in for `prettier --prose-wrap always --print-width 100`. Only paragraph text is
-- rewrapped; every other construct is copied through untouched, because rewrapping them
-- corrupts the document:
--
--   fenced code (``` / ~~~)   whitespace is significant
--   indented code (4 spaces)  same
--   tables (| ... |)          column alignment is the syntax
--   headings, hrules          must stay on one line
--   YAML front matter         not markdown at all
--   link definitions          [id]: url "title" cannot be split
--   HTML blocks               unknown semantics, leave alone
--
-- List items and blockquotes ARE wrapped, preserving their marker and indenting
-- continuation lines to line up under the text.

-- Fallback width, used when a buffer has no 'textwidth'. Every entry point takes an
-- optional width that overrides it, and markdown buffers get 'textwidth' seeded to this
-- below -- so `:setlocal textwidth=80` changes this formatter and gq together.
local DEFAULT_WIDTH = 100

local M = {}

---Width to wrap `bufnr` at: explicit argument, else the buffer's 'textwidth', else the
---default.
local function width_for(bufnr, override)
  if override and override > 0 then
    return override
  end
  local tw = vim.bo[bufnr].textwidth
  return (tw and tw > 0) and tw or DEFAULT_WIDTH
end

---Greedy word wrap. `first` prefixes line one, `cont` every line after it. A word longer
---than the budget gets its own line rather than being broken -- URLs must stay intact.
local function wrap(text, first, cont, width)
  local words = vim.split(text, '%s+', { trimempty = true })
  if #words == 0 then
    return { first }
  end
  local out, line = {}, first .. words[1]
  for i = 2, #words do
    local candidate = line .. ' ' .. words[i]
    if vim.fn.strdisplaywidth(candidate) <= width then
      line = candidate
    else
      out[#out + 1] = line
      line = cont .. words[i]
    end
  end
  out[#out + 1] = line
  return out
end

---Marker and continuation indent for a list item, or nil if `line` is not one.
local function list_prefix(line)
  local indent = line:match '^(%s*)[%-%*%+]%s+'
  if not indent then
    indent = line:match '^(%s*)%d+[%.%)]%s+'
  end
  if not indent then
    return nil
  end
  local first = line:match '^(%s*[^%s]+%s+)'
  return first, string.rep(' ', vim.fn.strdisplaywidth(first))
end

local function blockquote_prefix(line)
  return line:match '^(%s*>+%s*)'
end

---True for any line that must be emitted verbatim and never joined into a paragraph.
local function is_opaque(line)
  return line:match '^%s*$' -- blank
    or line:match '^%s*#' -- heading
    or line:match '^%s*|' -- table row
    or line:match '^%s*[%-%*_]%s*[%-%*_]%s*[%-%*_][%s%-%*_]*$' -- horizontal rule
    or line:match '^%s*%[[^%]]+%]:%s' -- link definition
    or line:match '^%s*<' -- html
    or line:match '^    ' -- indented code block
    or line:match '^\t'
end

---Reflow a whole document.
---@param lines string[]
---@param width? integer  columns to wrap at; defaults to DEFAULT_WIDTH
---@return string[]
function M.format(lines, width)
  width = (width and width > 0) and width or DEFAULT_WIDTH
  local out, i, n = {}, 1, #lines

  -- YAML front matter: copy verbatim up to and including the closing delimiter.
  if lines[1] and lines[1]:match '^%-%-%-%s*$' then
    out[#out + 1] = lines[1]
    i = 2
    while i <= n and not lines[i]:match '^%-%-%-%s*$' do
      out[#out + 1] = lines[i]
      i = i + 1
    end
    if i <= n then
      out[#out + 1] = lines[i]
      i = i + 1
    end
  end

  while i <= n do
    local line = lines[i]
    local fence = line:match '^%s*(```+)' or line:match '^%s*(~~~+)'

    if fence then
      -- Copy the fence and everything to its close, including a stray unclosed fence.
      out[#out + 1] = line
      i = i + 1
      while i <= n do
        out[#out + 1] = lines[i]
        local closed = lines[i]:match('^%s*' .. fence)
        i = i + 1
        if closed then
          break
        end
      end
    elseif is_opaque(line) then
      out[#out + 1] = line
      i = i + 1
    else
      -- A paragraph: this line plus every following line that is plain continuation.
      local first, cont
      local lp_first, lp_cont = list_prefix(line)
      local bq = blockquote_prefix(line)
      local body

      if lp_first then
        first, cont = lp_first, lp_cont
        body = line:sub(#lp_first + 1)
      elseif bq then
        first, cont = bq, bq
        body = line:sub(#bq + 1)
      else
        local indent = line:match '^(%s*)'
        first, cont = indent, indent
        body = line:sub(#indent + 1)
      end

      local parts = { body }
      i = i + 1
      while i <= n do
        local nxt = lines[i]
        if is_opaque(nxt) or list_prefix(nxt) then
          break
        end
        if (blockquote_prefix(nxt) ~= nil) ~= (bq ~= nil) then
          break
        end
        -- A hard line break (two trailing spaces) is meaningful; end the chunk there.
        if parts[#parts]:match '  $' then
          break
        end
        local stripped = bq and nxt:sub(#(blockquote_prefix(nxt) or '') + 1) or nxt
        parts[#parts + 1] = vim.trim(stripped)
        i = i + 1
      end

      local text = table.concat(parts, ' ')
      local hard = text:match '  $'
      vim.list_extend(out, wrap(vim.trim(text), first, cont, width))
      if hard then
        out[#out] = out[#out] .. '  '
      end
    end
  end

  return out
end

---Reflow `bufnr` in place, preserving the cursor line.
---@param bufnr? integer
---@param width? integer  overrides the buffer's 'textwidth' for this run only
function M.format_buf(bufnr, width)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local formatted = M.format(lines, width_for(bufnr, width))
  if table.concat(lines, '\n') == table.concat(formatted, '\n') then
    return false
  end
  local win = vim.api.nvim_get_current_win()
  local cursor = vim.api.nvim_win_get_cursor(win)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, formatted)
  cursor[1] = math.min(cursor[1], vim.api.nvim_buf_line_count(bufnr))
  pcall(vim.api.nvim_win_set_cursor, win, cursor)
  return true
end

-- :MdFormat        wrap at the buffer's 'textwidth'
-- :MdFormat 80     wrap at 80 for this run only
vim.api.nvim_create_user_command('MdFormat', function(cmd)
  M.format_buf(nil, tonumber(cmd.args))
end, { nargs = '?', desc = "Reflow markdown prose to 'textwidth' (or the given width)" })

local group = vim.api.nvim_create_augroup('markdown-format', { clear = true })

-- No format-on-save: reflowing prose rewrites lines you did not touch, which makes for
-- noisy diffs. Trigger it explicitly with <leader>f or :MdFormat.

---Per-buffer setup. Buffer-local <leader>f, since the LSP mapping in core/lsp.lua only
---attaches where a language server is running and there is none for markdown here.
local function setup_buf(bufnr)
  -- Only seed 'textwidth' if nothing else set it, so a ftplugin, modeline or :setlocal
  -- keeps precedence.
  if vim.bo[bufnr].textwidth == 0 then
    vim.bo[bufnr].textwidth = DEFAULT_WIDTH
  end
  vim.keymap.set('n', '<leader>f', function()
    M.format_buf(bufnr)
  end, { buffer = bufnr, desc = 'Format markdown' })
end

vim.api.nvim_create_autocmd('FileType', {
  group = group,
  pattern = 'markdown',
  callback = function(args)
    setup_buf(args.buf)
  end,
})

-- If this module is lazy-loaded FROM a `FileType markdown` autocmd, that event has
-- already fired for the buffer that triggered the load, so the autocmd above will miss
-- it. Apply to any markdown buffer already open.
for _, b in ipairs(vim.api.nvim_list_bufs()) do
  if vim.api.nvim_buf_is_loaded(b) and vim.bo[b].filetype == 'markdown' then
    setup_buf(b)
  end
end

return M
