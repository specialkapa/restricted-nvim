-- Statusline with no plugins.
--
-- Mirrors the lualine layout from the main config:
--   mode | branch | file [+] crumbs      macro  diff  diagnostics  enc  ft | line:col | %
--
-- Every section is built from data Neovim already has: the branch is read straight out
-- of .git/HEAD (no subprocess), and the diff counts are core.gitsigns' hunks, so they
-- follow unsaved edits. Nothing shells out during a redraw -- 'statusline' is
-- re-evaluated on almost every keystroke, so it must stay cheap.
--
-- Breadcrumbs come from LSP textDocument/documentSymbol, the same source nvim-navic
-- uses. NOT treesitter, so they work here with ty attached.

local M = {}

-- Plain ASCII by default so this renders in a bare terminal with no patched font.
local ICONS = {
  branch = '', -- ' ' with a Nerd Font
  modified = '[+]',
  readonly = '[RO]',
  error = 'E',
  warn = 'W',
  added = '+',
  changed = '~',
  removed = '-',
}

-- Section / component separators. Standard Unicode -- no Nerd Font needed, unlike the
-- powerline glyphs (U+E0B0..U+E0B3) the main config uses, which live in the Private Use
-- Area.
--
-- U+258C fills the LEFT half of its cell and U+2590 the right. Drawn in the adjacent
-- section's colour just after (or before) that section, they read as a solid taper
-- rather than a separate glyph -- which is exactly the powerline effect. That is why
-- each one needs its own highlight group with fg set to the block's background.
local SEP = {
  section = { left = '\u{258C}', right = '\u{2590}' }, -- ▌ ▐
  component = { left = '\u{2502}', right = '\u{2502}' }, -- │
}

-- Sections below this window width are dropped, matching lualine's hide_in_width.
local NARROW = 100

-- Breadcrumb separator, and how many columns the trail may occupy before it is
-- truncated from the left (the innermost symbol is the one you care about).
local CRUMB_SEP = ' > '
local CRUMB_MAX = 60

-- ---------------------------------------------------------------------------
-- Highlights, derived from groups every colorscheme provides.
-- ---------------------------------------------------------------------------

local function hl_get(name)
  if vim.api.nvim_get_hl then
    local ok, t = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
    if ok then
      return t
    end
  end
  local ok, t = pcall(vim.api.nvim_get_hl_by_name, name, true)
  if ok then
    return { fg = t.foreground, bg = t.background }
  end
  return {}
end

---First candidate whose foreground differs from Normal's. Neovim's default colorscheme
---leaves several syntax groups at Normal's fg, so "first that exists" is not enough.
local function accent(candidates, fallback)
  local normal = hl_get('Normal')
  for _, name in ipairs(candidates) do
    if vim.fn.hlexists(name) == 1 then
      local h = hl_get(name)
      if h.fg and h.fg ~= normal.fg then
        return h.fg
      end
    end
  end
  return fallback or normal.fg
end

-- Mode key -> { label, accent group candidates }
local MODES = {
  n = { 'NORMAL', { 'Identifier', 'Function', 'Directory' } },
  no = { 'O-PEND', { 'Identifier', 'Function' } },
  v = { 'VISUAL', { 'WarningMsg', 'DiagnosticWarn', 'Special' } },
  V = { 'V-LINE', { 'WarningMsg', 'DiagnosticWarn', 'Special' } },
  ['\22'] = { 'V-BLOCK', { 'WarningMsg', 'DiagnosticWarn', 'Special' } },
  s = { 'SELECT', { 'WarningMsg', 'Special' } },
  S = { 'S-LINE', { 'WarningMsg', 'Special' } },
  i = { 'INSERT', { 'String', 'Added', 'DiagnosticOk' } },
  ic = { 'INSERT', { 'String', 'Added', 'DiagnosticOk' } },
  R = { 'REPLACE', { 'Removed', 'DiagnosticError', 'ErrorMsg' } },
  c = { 'COMMAND', { 'Directory', 'Special', 'Function' } },
  t = { 'TERMINAL', { 'String', 'Added' } },
  r = { 'PROMPT', { 'Comment' } },
  ['!'] = { 'SHELL', { 'Comment' } },
}

---Highlight group name for a mode key: non-word characters are not legal in a group
---name, so \22 (visual block) and ! are folded to 'x'.
local function mode_hl_name(key)
  return 'StlMode' .. key:gsub('%W', 'x')
end

local function setup_highlights()
  local normal, statusline = hl_get('Normal'), hl_get('StatusLine')
  local bg = statusline.bg or normal.bg
  local fg = statusline.fg or normal.fg

  vim.api.nvim_set_hl(0, 'StlBase', { fg = fg, bg = bg })
  vim.api.nvim_set_hl(0, 'StlDim', { fg = accent({ 'Comment' }, fg), bg = bg })
  vim.api.nvim_set_hl(0, 'StlBranch', { fg = accent({ 'Identifier', 'Function' }), bg = bg })
  vim.api.nvim_set_hl(0, 'StlFile', { fg = fg, bg = bg, bold = true })
  vim.api.nvim_set_hl(0, 'StlError', { fg = accent({ 'DiagnosticError', 'Removed', 'ErrorMsg' }), bg = bg })
  vim.api.nvim_set_hl(0, 'StlWarn', { fg = accent({ 'DiagnosticWarn', 'WarningMsg' }), bg = bg })
  vim.api.nvim_set_hl(0, 'StlAdd', { fg = accent({ 'Added', 'DiagnosticOk', 'String' }), bg = bg })
  vim.api.nvim_set_hl(0, 'StlChange', { fg = accent({ 'Changed', 'DiagnosticWarn', 'WarningMsg' }), bg = bg })
  vim.api.nvim_set_hl(0, 'StlDelete', { fg = accent({ 'Removed', 'DiagnosticError' }), bg = bg })
  vim.api.nvim_set_hl(0, 'StlMacro', { fg = accent({ 'DiagnosticError', 'Removed' }), bg = bg, bold = true })

  -- Position block on the right, and its separator.
  local pos_bg = accent({ 'Comment' }, fg)
  vim.api.nvim_set_hl(0, 'StlPos', { fg = normal.bg, bg = pos_bg })
  vim.api.nvim_set_hl(0, 'StlPosSep', { fg = pos_bg, bg = bg })

  -- One inverted block per mode, plus a separator carrying that block's colour as its
  -- FOREGROUND on the base background -- that is what makes the taper read as solid.
  for key, spec in pairs(MODES) do
    local mode_bg = accent(spec[2])
    vim.api.nvim_set_hl(0, mode_hl_name(key), { fg = normal.bg, bg = mode_bg, bold = true })
    vim.api.nvim_set_hl(0, mode_hl_name(key) .. 'Sep', { fg = mode_bg, bg = bg })
  end
end

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

---Escape user-controlled text: a '%' in a filename would be read as a statusline item.
local function esc(text)
  return (text:gsub('%%', '%%%%'))
end

local function hl(group, text)
  return '%#' .. group .. '#' .. text
end

-- ---------------------------------------------------------------------------
-- Git: branch from .git/HEAD. Diff counts come from core.gitsigns (section_diff).
-- ---------------------------------------------------------------------------

local branch_cache = {}

local function git_dir(path)
  local found = vim.fs.find('.git', { upward = true, path = path })[1]
  if not found then
    return nil
  end
  local stat = (vim.uv or vim.loop).fs_stat(found)
  if stat and stat.type == 'file' then
    -- A worktree or submodule: .git is a file containing `gitdir: <path>`.
    local line = (vim.fn.readfile(found, '', 1) or {})[1] or ''
    local target = line:match('^gitdir:%s*(.+)$')
    return target and vim.fs.normalize(target) or nil
  end
  return found
end

---Current branch, or a short SHA when detached. Reading HEAD directly avoids spawning
---git on a path that runs many times per second.
local function git_branch(path)
  local dir = git_dir(path)
  if not dir then
    return ''
  end
  if branch_cache[dir] ~= nil then
    return branch_cache[dir]
  end
  local head = (vim.fn.readfile(dir .. '/HEAD', '', 1) or {})[1] or ''
  local name = head:match('^ref:%s*refs/heads/(.+)$') or head:sub(1, 7)
  branch_cache[dir] = name
  return name
end

-- ---------------------------------------------------------------------------
-- Breadcrumbs, from LSP document symbols.
--
-- The server is asked for the symbol tree once per idle moment / write, not per
-- keystroke -- the request is a round trip and the statusline redraws constantly. The
-- cursor walk over the cached tree is what runs on every redraw, and that is cheap.
-- ---------------------------------------------------------------------------

local symbol_cache = {}

---Both response shapes are legal: DocumentSymbol[] is a tree with `range` + `children`,
---SymbolInformation[] is a flat list where the range hangs off `location`.
local function node_range(node)
  return node.range or (node.location and node.location.range)
end

local function contains(range, line, col)
  if not range then
    return false
  end
  local from, to = range.start, range['end']
  if line < from.line or line > to.line then
    return false
  end
  if line == from.line and col < from.character then
    return false
  end
  if line == to.line and col > to.character then
    return false
  end
  return true
end

---Names of the symbols enclosing (line, col), outermost first.
local function symbol_chain(nodes, line, col, acc)
  acc = acc or {}
  for _, node in ipairs(nodes or {}) do
    if contains(node_range(node), line, col) then
      acc[#acc + 1] = node.name
      -- Siblings do not overlap, so the first hit is the only one worth descending.
      if node.children then
        symbol_chain(node.children, line, col, acc)
      end
      break
    end
  end
  return acc
end

local function refresh_symbols(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) or vim.bo[bufnr].buftype ~= '' then
    return
  end
  local clients = vim.lsp.get_clients({ bufnr = bufnr, method = 'textDocument/documentSymbol' })
  if #clients == 0 then
    symbol_cache[bufnr] = nil
    return
  end
  local params = { textDocument = vim.lsp.util.make_text_document_params(bufnr) }
  pcall(vim.lsp.buf_request, bufnr, 'textDocument/documentSymbol', params, function(err, result)
    if err or type(result) ~= 'table' then
      return
    end
    vim.schedule(function()
      if vim.api.nvim_buf_is_valid(bufnr) then
        symbol_cache[bufnr] = result
        vim.cmd.redrawstatus()
      end
    end)
  end)
end

local function section_crumbs(bufnr, winid)
  local tree = symbol_cache[bufnr]
  if not tree then
    return ''
  end
  local pos = vim.api.nvim_win_get_cursor(winid)
  local names = symbol_chain(tree, pos[1] - 1, pos[2])
  if #names == 0 then
    return ''
  end

  local trail = table.concat(names, CRUMB_SEP)
  -- Truncate from the left: the enclosing class matters less than the function you are
  -- actually standing in.
  while #trail > CRUMB_MAX and #names > 1 do
    table.remove(names, 1)
    trail = '..' .. CRUMB_SEP .. table.concat(names, CRUMB_SEP)
  end
  return hl('StlDim', esc(trail) .. ' ')
end

-- ---------------------------------------------------------------------------
-- Sections
-- ---------------------------------------------------------------------------

local function section_mode()
  local mode = vim.api.nvim_get_mode().mode
  local key = MODES[mode] and mode or mode:sub(1, 1)
  local spec = MODES[key] or { mode:upper(), { 'Identifier' } }
  local out = hl(mode_hl_name(key), ' ' .. spec[1] .. ' ')
  if SEP.section.left ~= '' then
    out = out .. hl(mode_hl_name(key) .. 'Sep', SEP.section.left)
  end
  return out
end

---Join non-empty pieces with the component separator.
local function join(pieces, sep)
  local out, first = '', true
  for _, piece in ipairs(pieces) do
    if piece ~= '' then
      if not first and sep ~= '' then
        out = out .. hl('StlDim', ' ' .. sep)
      end
      out = out .. piece
      first = false
    end
  end
  return out
end

local function section_branch(path)
  local name = git_branch(path)
  if name == '' then
    return ''
  end
  local prefix = ICONS.branch ~= '' and (ICONS.branch .. ' ') or ''
  return hl('StlBranch', ' ' .. prefix .. esc(name) .. ' ')
end

local function section_file(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  local shown = name == '' and '[No Name]' or vim.fn.fnamemodify(name, ':.')
  local out = hl('StlFile', ' ' .. esc(shown))
  if vim.bo[bufnr].modified then
    out = out .. hl('StlChange', ' ' .. ICONS.modified)
  end
  if vim.bo[bufnr].readonly or not vim.bo[bufnr].modifiable then
    out = out .. hl('StlDim', ' ' .. ICONS.readonly)
  end
  return out .. hl('StlBase', ' ')
end

local function section_macro()
  local reg = vim.fn.reg_recording()
  if reg == '' then
    return ''
  end
  return hl('StlMacro', ' recording @' .. reg .. ' ')
end

---Read from core.gitsigns on each redraw: a loop over a handful of hunks, no git call.
---Empty if gitsigns is not loaded, so the statusline still works without it.
local function section_diff(bufnr)
  local gitsigns = package.loaded['core.gitsigns']
  local d = gitsigns and gitsigns.counts(bufnr)
  if not d or (d.added == 0 and d.changed == 0 and d.removed == 0) then
    return ''
  end
  local out = ' '
  if d.added > 0 then
    out = out .. hl('StlAdd', ICONS.added .. d.added .. ' ')
  end
  if d.changed > 0 then
    out = out .. hl('StlChange', ICONS.changed .. d.changed .. ' ')
  end
  if d.removed > 0 then
    out = out .. hl('StlDelete', ICONS.removed .. d.removed .. ' ')
  end
  return out
end

local function section_diagnostics(bufnr)
  local errors, warns
  if vim.diagnostic.count then
    local counts = vim.diagnostic.count(bufnr)
    errors = counts[vim.diagnostic.severity.ERROR] or 0
    warns = counts[vim.diagnostic.severity.WARN] or 0
  else
    errors = #vim.diagnostic.get(bufnr, { severity = vim.diagnostic.severity.ERROR })
    warns = #vim.diagnostic.get(bufnr, { severity = vim.diagnostic.severity.WARN })
  end
  if errors == 0 and warns == 0 then
    return ''
  end
  local out = ' '
  if errors > 0 then
    out = out .. hl('StlError', ICONS.error .. errors .. ' ')
  end
  if warns > 0 then
    out = out .. hl('StlWarn', ICONS.warn .. warns .. ' ')
  end
  return out
end

-- ---------------------------------------------------------------------------
-- Render
-- ---------------------------------------------------------------------------

---Called from 'statusline' for every window. vim.g.statusline_winid names the window
---being drawn, which is how the inactive variant is distinguished.
function M.render()
  local winid = vim.g.statusline_winid or vim.api.nvim_get_current_win()
  if not vim.api.nvim_win_is_valid(winid) then
    return ''
  end
  local bufnr = vim.api.nvim_win_get_buf(winid)
  local active = winid == vim.api.nvim_get_current_win()

  if not active then
    local shown = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ':.')
    return hl('StlDim', ' ' .. esc(shown)) .. '%=' .. hl('StlDim', '%l:%c ')
  end

  local path = vim.api.nvim_buf_get_name(bufnr)
  if path == '' then
    path = vim.fn.getcwd()
  end
  local wide = vim.api.nvim_win_get_width(winid) > NARROW

  local left = section_mode()
    .. join({ section_branch(path), section_file(bufnr) .. section_crumbs(bufnr, winid) }, SEP.component.left)

  local enc, ft = '', ''
  if wide then
    local e = vim.bo[bufnr].fileencoding
    if e ~= '' then
      enc = hl('StlDim', ' ' .. e .. ' ')
    end
    local f = vim.bo[bufnr].filetype
    if f ~= '' then
      ft = hl('StlDim', ' ' .. f .. ' ')
    end
  end

  local right = join({
    section_macro(),
    wide and section_diff(bufnr) or '',
    section_diagnostics(bufnr),
    enc,
    ft,
  }, SEP.component.right)

  -- Position block, tapered back into the bar by its own separator.
  if SEP.section.right ~= '' then
    right = right .. hl('StlPosSep', SEP.section.right)
  end
  right = right .. hl('StlPos', ' %l:%c %p%% ')

  return left .. hl('StlBase', '%=') .. right
end

_G.UserStatusline = M.render
vim.o.statusline = '%!v:lua.UserStatusline()'

setup_highlights()

local group = vim.api.nvim_create_augroup('user-statusline', { clear = true })

vim.api.nvim_create_autocmd('ColorScheme', { group = group, callback = setup_highlights })

-- Branch only changes on a checkout, so invalidate rather than poll.
vim.api.nvim_create_autocmd({ 'BufEnter', 'FocusGained', 'DirChanged' }, {
  group = group,
  callback = function()
    branch_cache = {}
  end,
})

vim.api.nvim_create_autocmd('BufWritePost', {
  group = group,
  callback = function(args)
    refresh_symbols(args.buf)
  end,
})

-- gitsigns re-diffs after a pause in typing, i.e. after the redraw the edit itself
-- caused, so the counts need a redraw of their own.
vim.api.nvim_create_autocmd('User', {
  group = group,
  pattern = 'GitSignsUpdate',
  callback = function()
    vim.cmd.redrawstatus()
  end,
})

-- Symbol ranges shift as you type, so re-request when you pause or leave insert --
-- never on TextChanged, which would be a request per keystroke.
vim.api.nvim_create_autocmd({ 'LspAttach', 'CursorHold', 'InsertLeave', 'BufEnter' }, {
  group = group,
  callback = function(args)
    refresh_symbols(args.buf)
  end,
})

-- Redraw immediately when a macro starts or stops, which no other event covers.
vim.api.nvim_create_autocmd({ 'RecordingEnter', 'RecordingLeave' }, {
  group = group,
  callback = function()
    vim.cmd.redrawstatus()
  end,
})

vim.api.nvim_create_autocmd('BufDelete', {
  group = group,
  callback = function(args)
    symbol_cache[args.buf] = nil
  end,
})

return M
