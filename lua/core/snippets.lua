-- Snippets with no plugins, standing in for LuaSnip. vim.snippet (0.11-era) does the
-- expansion and placeholder jumps; this file only holds the snippet table and the key.
--
-- Type a trigger word, then <C-l>: the word is replaced by the snippet. <C-l> / <C-h>
-- then jump forward / back through its placeholders (<C-h> lives in core/completion.lua).
--
-- Bodies use LSP snippet syntax:
--   $1, $2     tabstops, visited in order
--   ${1:text}  tabstop with default text, selected so typing replaces it
--   $0         where the cursor ends up (never selected: give defaults a number instead)
--   \t         one indent level ('expandtab' / 'shiftwidth' are respected)
-- Later lines are indented to match the line the trigger was typed on.

if not vim.snippet then
  return
end

local M = {}

-- Keyed by filetype; `all` applies everywhere and loses to a filetype entry of the same name.
M.snippets = {
  all = {
    todo = 'TODO: $0',
  },
  python = {
    main = 'if __name__ == "__main__":\n\t${1:main()}',
    def = 'def ${1:name}(${2}) -> ${3:None}:\n\t${4:pass}',
    cls = 'class ${1:Name}:\n\tdef __init__(self${2}) -> None:\n\t\t${3:pass}',
    fori = 'for ${1:i} in range(${2:n}):\n\t$0',
    try = 'try:\n\t${1:pass}\nexcept ${2:Exception} as ${3:e}:\n\t${4:raise}',
    with = 'with ${1:open(${2:path})} as ${3:f}:\n\t$0',
    pdb = 'breakpoint()',
    test = 'def test_${1:name}() -> None:\n\t${2:assert True}',
  },
  sql = {
    sel = 'SELECT ${1:*}\nFROM ${2:table}\nWHERE ${3:1 = 1}\nLIMIT ${4:100};$0',
    cnt = 'SELECT COUNT(*)\nFROM ${1:table};$0',
  },
}

-- Snippets can also be plain files: snippets/<filetype>/<trigger>.snippet (or
-- snippets/all/...) under the config dir, with the body written out as-is -- real
-- newlines, real indentation, same $1 / ${1:text} syntax. :SnippetAdd writes these.
-- Read at expand time, so a new or edited file works without restarting.
M.dir = vim.fn.stdpath 'config' .. '/snippets'

local function snippet_file(ft, word)
  return M.dir .. '/' .. ft .. '/' .. word .. '.snippet'
end

local function read_file(ft, word)
  local path = snippet_file(ft, word)
  if vim.fn.filereadable(path) == 1 then
    return table.concat(vim.fn.readfile(path), '\n')
  end
end

local function lookup(word)
  local ft = vim.bo.filetype
  return (M.snippets[ft] or {})[word] or read_file(ft, word) or M.snippets.all[word] or read_file('all', word)
end

---Expand the snippet named by the word before the cursor. Returns false if there is none.
M.expand = function()
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  local word = vim.api.nvim_get_current_line():sub(1, col):match '[%w_]+$'
  local body = word and lookup(word)
  if not body then
    return false
  end
  vim.api.nvim_buf_set_text(0, row - 1, col - #word, row - 1, col, {})
  vim.api.nvim_win_set_cursor(0, { row, col - #word })
  vim.snippet.expand(body)
  return true
end

local function expand_or_jump()
  if vim.snippet.active { direction = 1 } then
    vim.snippet.jump(1)
  else
    M.expand()
  end
end

-- Expr mapping so an open completion menu (likely, since the trigger word itself opens
-- the autotrigger) is closed with <C-e> before the trigger word is replaced.
vim.keymap.set({ 'i', 's' }, '<C-l>', function()
  return (vim.fn.pumvisible() == 1 and '<C-e>' or '') .. '<Cmd>lua require("core.snippets").expand_or_jump()<CR>'
end, { expr = true, desc = 'Snippet expand or jump forward' })

M.expand_or_jump = expand_or_jump

-- ---------------------------------------------------------------------------
-- :'<,'>SnippetAdd [trigger] -- save the selected lines as a snippet for this filetype
-- (prompts for the trigger if not given), then open the file in a split so you can turn
-- parts of it into ${1:placeholders}. Whole lines only, even from a charwise selection.
--
-- The text is stored literally: \ $ } are escaped so code containing them (f-strings,
-- shell vars) expands as written. Common indentation is removed and each 'shiftwidth'
-- of leading spaces becomes a tab, so it re-indents to whatever buffer it expands in.
-- ---------------------------------------------------------------------------

local function to_body(lines)
  local indent = math.huge
  for _, l in ipairs(lines) do
    if l:match '%S' then
      indent = math.min(indent, #l:match '^%s*')
    end
  end
  local sw = vim.fn.shiftwidth()
  local out = {}
  for i, l in ipairs(lines) do
    l = l:sub((indent == math.huge and 0 or indent) + 1)
    local lead, rest = l:match '^( *)(.*)$'
    rest = rest:gsub('\\', '\\\\'):gsub('%$', '\\$'):gsub('}', '\\}')
    out[i] = string.rep('\t', math.floor(#lead / sw)) .. string.rep(' ', #lead % sw) .. rest
  end
  return out
end

vim.api.nvim_create_user_command('SnippetAdd', function(args)
  local lines = vim.api.nvim_buf_get_lines(0, args.line1 - 1, args.line2, false)
  local ft = vim.bo.filetype ~= '' and vim.bo.filetype or 'all'
  local function save(word)
    if not word or word == '' then
      return
    end
    if not word:match '^[%w_]+$' then
      vim.notify('Snippet trigger must be letters, digits or _', vim.log.levels.ERROR)
      return
    end
    local path = snippet_file(ft, word)
    local body = to_body(lines)
    local function write()
      vim.fn.mkdir(vim.fs.dirname(path), 'p')
      vim.fn.writefile(body, path)
      vim.cmd('split ' .. vim.fn.fnameescape(path))
      vim.notify('Snippet ' .. word .. ' saved for ' .. ft)
    end
    if vim.fn.filereadable(path) == 0 then
      return write()
    end
    -- Exists already: show the old body against the new one before replacing it.
    local info = { 'Trigger    ' .. word .. '   (' .. ft .. ')', 'File       ' .. vim.fn.fnamemodify(path, ':~'), '', 'Current' }
    local function add(src, hl)
      for i, l in ipairs(src) do
        if i > 5 then
          info[#info + 1] = { ('  ... %d more lines'):format(#src - 5), 'Comment' }
          break
        end
        info[#info + 1] = { '  ' .. l:gsub('\t', '  '), hl }
      end
    end
    add(vim.fn.readfile(path), 'DiffDelete')
    info[#info + 1] = ''
    info[#info + 1] = 'New'
    add(body, 'DiffAdd')
    require('lib.prompt').confirm({ title = 'Overwrite snippet', info = info, on_yes = write })
  end
  if args.args ~= '' then
    save(args.args)
  else
    local info = { 'Filetype   ' .. ft, '' }
    for i, l in ipairs(lines) do
      if i > 6 then
        info[#info + 1] = { ('  ... %d more lines'):format(#lines - 6), 'Comment' }
        break
      end
      info[#info + 1] = { '  ' .. l:gsub('\t', '  '), 'Comment' }
    end
    require('lib.prompt').input({
      title = 'New snippet',
      info = info,
      box_title = 'trigger word (letters, digits, _)',
      on_submit = save,
    })
  end
end, { range = true, nargs = '?', desc = 'Save the selected lines as a snippet' })

-- `:` from visual mode fills in '<,'>; from normal mode the range is the current line.
vim.keymap.set({ 'n', 'x' }, '<leader>as', ':SnippetAdd<CR>', { desc = '[A]dd [S]nippet from selection' })

return M
