-- Peek at a definition without leaving the buffer.
--
--   <leader>pd  peek the definition of the symbol under the cursor
--   <leader>pt  peek its type definition
--
-- Asks the language server for the location, then renders the target in a float on the
-- right-hand side, aligned with your cursor line so the usage stays visible beside the
-- definition. Your buffer, window layout and jumplist are untouched.
--
-- Inside the float: <CR> jump there for real, q / <Esc> close, <C-d>/<C-u> scroll.

local M = {}

local HEIGHT = 30 -- lines of the definition to show
local CONTEXT_BEFORE = 1 -- lines above it, so a decorator or comment is visible
local BORDER = 'single'
local GAP = 4 -- columns between the cursor and the float, so the symbol stays readable
local MIN_WIDTH = 40 -- below this the excerpt is unreadable; flip sides instead

local ns = vim.api.nvim_create_namespace('peek')
local state = { win = nil, target = nil }

-- Colours, derived from the editor's own groups.
--
-- `style = 'minimal'` points 'winhighlight' at NormalFloat, which most colorschemes
-- render darker than Normal -- and which a hand-written theme may not define at all,
-- leaving a black box. Deriving from Normal makes the peek sit on the same background as
-- the rest of the session. Same approach as core/picker.lua and core/gitblame.lua.
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

local function setup_highlights()
  local normal, comment = hl_get('Normal'), hl_get('Comment')
  vim.api.nvim_set_hl(0, 'PeekNormal', { fg = normal.fg, bg = normal.bg })
  vim.api.nvim_set_hl(0, 'PeekBorder', { fg = comment.fg or normal.fg, bg = normal.bg })
  vim.api.nvim_set_hl(0, 'PeekTitle', { fg = normal.fg, bg = normal.bg, bold = true })
  -- The definition line stays marked while you scroll away from it.
  vim.api.nvim_set_hl(0, 'PeekTarget', { link = 'Visual', default = true })
end

setup_highlights()
vim.api.nvim_create_autocmd('ColorScheme', {
  group = vim.api.nvim_create_augroup('peek-highlights', { clear = true }),
  callback = setup_highlights,
})

local WINHL = 'Normal:PeekNormal,FloatBorder:PeekBorder,FloatTitle:PeekTitle,EndOfBuffer:PeekNormal'

local function close()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    pcall(vim.api.nvim_win_close, state.win, true)
  end
  if state.target and vim.api.nvim_buf_is_valid(state.target) then
    vim.api.nvim_buf_clear_namespace(state.target, ns, 0, -1)
  end
  state.win, state.target = nil, nil
end

---A Location has uri+range; a LocationLink has targetUri+targetRange. Servers may return
---either, or an array of them.
local function first_location(result)
  if type(result) ~= 'table' then
    return nil
  end
  if result.uri or result.targetUri then
    return result, 1
  end
  local list = result
  if #list == 0 then
    return nil
  end
  return list[1], #list
end

local function location_parts(loc)
  local uri = loc.uri or loc.targetUri
  -- targetSelectionRange points at the NAME; targetRange at the whole body. The name is
  -- the better anchor -- starting at the body would often begin on a decorator line.
  local range = loc.range or loc.targetSelectionRange or loc.targetRange
  return uri, range
end

---Render `loc` in a float. Separated from the LSP round trip so it can be driven
---directly with a synthetic location.
---@param loc table a Location or LocationLink
---@param total integer how many results the server returned
function M.show_location(loc, total)
  local uri, range = location_parts(loc)
  if not uri or not range then
    return
  end

  -- Show the TARGET BUFFER ITSELF rather than a copy of a few lines. That is what
  -- makes scrolling work past the excerpt -- the whole file is there -- and it gets
  -- syntax highlighting, folds and unsaved changes for free.
  local target = vim.uri_to_bufnr(uri)
  vim.fn.bufload(target)

  close()

  local pref_width = math.min(90, math.max(MIN_WIDTH, math.floor(vim.o.columns * 0.45)))
  local height = math.max(5, math.min(HEIGHT, vim.o.lines - 6))

  -- Anchor beside the symbol rather than at the screen edge: near enough to relate the
  -- two, with GAP columns of clearance so the float never sits on top of what you are
  -- looking at. screenpos() gives the cursor's actual SCREEN cell, which accounts for
  -- the sign column, line numbers, wrapping and any splits to the left.
  local cursor = vim.api.nvim_win_get_cursor(0)
  local pos = vim.fn.screenpos(0, cursor[1], cursor[2] + 1)
  local cur_row, cur_col = pos.row - 1, pos.col - 1

  -- Borders cost 2 columns. Prefer the right of the cursor; fall back to the left; and
  -- rather than overlap the cursor when neither side fits at full width, NARROW the
  -- float to whatever the roomier side offers.
  local room_right = vim.o.columns - (cur_col + GAP) - 2
  local room_left = cur_col - GAP - 2
  local width, col
  if room_right >= MIN_WIDTH then
    width = math.min(pref_width, room_right)
    col = cur_col + GAP
  elseif room_left >= MIN_WIDTH then
    width = math.min(pref_width, room_left)
    col = cur_col - GAP - width - 2
  elseif room_left > room_right then
    width = math.max(20, room_left)
    col = math.max(0, cur_col - GAP - width - 2)
  else
    width = math.max(20, room_right)
    col = math.min(cur_col + GAP, math.max(0, vim.o.columns - width - 2))
  end

  -- Top of the float level with the cursor line, so the definition starts beside the
  -- usage; shifted up only if it would overflow the bottom.
  local row = math.max(0, math.min(cur_row, vim.o.lines - height - 4))

  local name = vim.fn.fnamemodify(vim.uri_to_fname(uri), ':.')
  local title = (' %s:%d '):format(name, range.start.line + 1)
  if total and total > 1 then
    title = (' %s:%d  (1 of %d) '):format(name, range.start.line + 1, total)
  end

  state.target = target
  state.win = vim.api.nvim_open_win(target, false, {
    relative = 'editor',
    width = width,
    height = height,
    col = col,
    row = row,
    style = 'minimal',
    border = BORDER,
    title = title,
    title_pos = 'center',
    focusable = true,
    zindex = 60,
  })
  -- Set after nvim_open_win: 'minimal' assigns winhighlight itself, so this overrides.
  vim.wo[state.win].winhighlight = WINHL
  vim.wo[state.win].wrap = false
  vim.wo[state.win].number = true
  vim.wo[state.win].cursorline = false

  local def_line = range.start.line + 1
  pcall(vim.api.nvim_win_set_cursor, state.win, { def_line, 0 })
  -- Put the definition near the top with a little context above it, rather than centred
  -- -- you want to read downwards from it.
  vim.api.nvim_win_call(state.win, function()
    vim.fn.winrestview({ topline = math.max(1, def_line - CONTEXT_BEFORE) })
  end)
  -- Mark the definition line so it stays identifiable once you scroll away.
  pcall(vim.api.nvim_buf_set_extmark, target, ns, range.start.line, 0, {
    line_hl_group = 'PeekTarget',
  })

  -- Keys are set on the ORIGINAL buffer: the float is not focused, so it is your window
  -- that receives them. <CR> and the scroll keys act on the float remotely.
  local origin = vim.api.nvim_get_current_buf()
  local function map(lhs, fn)
    vim.keymap.set('n', lhs, fn, { buffer = origin, nowait = true })
  end
  local mapped = { '<CR>', 'q', '<Esc>', '<C-d>', '<C-u>' }

  local function unmap()
    for _, lhs in ipairs(mapped) do
      pcall(vim.keymap.del, 'n', lhs, { buffer = origin })
    end
  end

  local function dismiss()
    unmap()
    close()
  end

  map('q', dismiss)
  map('<Esc>', dismiss)
  map('<CR>', function()
    dismiss()
    vim.cmd.edit(vim.fn.fnameescape(vim.uri_to_fname(uri)))
    pcall(vim.api.nvim_win_set_cursor, 0, { range.start.line + 1, range.start.character })
    vim.cmd 'normal! zz'
  end)
  local function scroll(delta)
    if not (state.win and vim.api.nvim_win_is_valid(state.win)) then
      return
    end
    vim.api.nvim_win_call(state.win, function()
      -- Clamped to the whole file now, not to a short excerpt.
      local line_count = vim.api.nvim_buf_line_count(target)
      local to = math.max(1, math.min(vim.fn.line('.') + delta, line_count))
      vim.api.nvim_win_set_cursor(state.win, { to, 0 })
      vim.cmd('normal! zz')
    end)
  end
  map('<C-d>', function()
    scroll(math.floor(HEIGHT / 2))
  end)
  map('<C-u>', function()
    scroll(-math.floor(HEIGHT / 2))
  end)

  -- Moving the cursor dismisses it, the way hover does.
  vim.api.nvim_create_autocmd({ 'CursorMoved', 'BufLeave', 'InsertEnter' }, {
    buffer = origin,
    once = true,
    callback = dismiss,
  })
end

---Ask the server for `method` at the cursor and peek the first result.
local function peek(method, label)
  local clients = vim.lsp.get_clients({ bufnr = 0, method = method })
  if #clients == 0 then
    vim.notify('no server supports ' .. label, vim.log.levels.WARN)
    return
  end
  -- offset_encoding must come from the client; guessing corrupts the position on any
  -- line containing non-ASCII.
  local params = vim.lsp.util.make_position_params(0, clients[1].offset_encoding)
  vim.lsp.buf_request(0, method, params, function(err, result)
    if err then
      vim.notify(label .. ': ' .. tostring(err.message or err), vim.log.levels.ERROR)
      return
    end
    local loc, total = first_location(result)
    if not loc then
      vim.notify('no ' .. label .. ' found', vim.log.levels.INFO)
      return
    end
    vim.schedule(function()
      M.show_location(loc, total)
    end)
  end)
end

function M.definition()
  peek('textDocument/definition', 'definition')
end

function M.type_definition()
  peek('textDocument/typeDefinition', 'type definition')
end

vim.keymap.set('n', '<leader>pd', M.definition, { desc = '[P]eek [D]efinition' })
vim.keymap.set('n', '<leader>pt', M.type_definition, { desc = '[P]eek [T]ype definition' })

return M
