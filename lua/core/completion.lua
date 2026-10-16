-- Autocompletion with no plugins.
--
-- On Neovim 0.11+ the work is done by vim.lsp.completion.enable(), called from the
-- LspAttach handler in core/lsp.lua. This file supplies the surrounding ergonomics:
-- 'completeopt', navigation keys and snippet jumps.
--
-- Keymaps mirror the nvim-cmp setup on the main machine so muscle memory carries across.

local M = {
  attach_border = function() end,
}

local has_native = vim.lsp.completion ~= nil and vim.lsp.completion.enable ~= nil

-- Matches cmp's `completion = { completeopt = 'menu,menuone,noinsert' }`.
-- noinsert (NOT noselect): the first entry is preselected but nothing is written into
-- the buffer until you confirm -- which is what makes a bare <C-y> always have something
-- to accept, exactly like cmp.confirm { select = true }.
local opts = { 'menu', 'menuone', 'noinsert' }
if has_native then
  -- No cmp equivalents -- cmp draws its own windows and does its own matching.
  -- popup: documentation in a floating window. fuzzy: subsequence matching.
  vim.list_extend(opts, { 'popup', 'fuzzy' })
end
vim.opt.completeopt = opts

vim.opt.pumheight = 12
vim.opt.shortmess:append 'c' -- silence "match 1 of 12" spam

local function feed(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), 'n', false)
end

-- Gate <Tab> menu navigation on a non-blank character behind the cursor, so <Tab> on an
-- empty line still indents.
local function has_words_before()
  local line, col = unpack(vim.api.nvim_win_get_cursor(0))
  if col == 0 then
    return false
  end
  local text = vim.api.nvim_buf_get_lines(0, line - 1, line, true)[1]
  return text:sub(col, col):match '%s' == nil
end

-- <C-n> / <C-p> / <C-y> need no mapping: with a menu open those are already Neovim's
-- native select-next, select-previous and accept.
--
-- <CR> is intentionally NOT mapped, matching the cmp config where the <CR>-to-confirm
-- line is left commented out. Accept with <C-y>.

vim.keymap.set('i', '<Tab>', function()
  if vim.fn.pumvisible() == 1 and has_words_before() then
    return '<C-n>'
  end
  return '<Tab>'
end, { expr = true, desc = 'Next completion or tab' })

vim.keymap.set('i', '<S-Tab>', function()
  return vim.fn.pumvisible() == 1 and '<C-p>' or '<S-Tab>'
end, { expr = true, desc = 'Previous completion' })

-- <C-j> / <C-k> move through the menu; with it closed they keep their insert-mode meaning
-- (newline / digraph).
vim.keymap.set('i', '<C-j>', function()
  return vim.fn.pumvisible() == 1 and '<C-n>' or '<C-j>'
end, { expr = true, desc = 'Next completion' })

vim.keymap.set('i', '<C-k>', function()
  return vim.fn.pumvisible() == 1 and '<C-p>' or '<C-k>'
end, { expr = true, desc = 'Previous completion' })

vim.keymap.set('i', '<C-Space>', function()
  if has_native then
    vim.lsp.completion.get()
  else
    feed '<C-x><C-o>'
  end
end, { desc = 'Trigger completion' })

-- <C-l> / <C-h> jump through snippet placeholders, standing in for LuaSnip. vim.snippet
-- is 0.11-era; on older builds the LSP client cannot expand snippets at all.
if vim.snippet then
  vim.keymap.set({ 'i', 's' }, '<C-l>', function()
    if vim.snippet.active { direction = 1 } then
      vim.snippet.jump(1)
    end
  end, { desc = 'Snippet jump forward' })

  vim.keymap.set({ 'i', 's' }, '<C-h>', function()
    if vim.snippet.active { direction = -1 } then
      vim.snippet.jump(-1)
    end
  end, { desc = 'Snippet jump backward' })
end

-- ---------------------------------------------------------------------------
-- Keyword autotrigger.
--
-- vim.lsp.completion's own `autotrigger` fires ONLY on the trigger characters the server
-- advertises -- for python that is basically `.`, so typing a bare identifier never opens
-- the menu. nvim-cmp triggered on any keyword character; this restores that. It doubles
-- as the autotrigger for Neovim < 0.11, where 'omnifunc' is the only route.
--
-- Once the menu is open Neovim filters it natively as you keep typing, so this fires at
-- most once per word rather than on every keystroke.
-- ---------------------------------------------------------------------------

local function trigger()
  if has_native then
    vim.lsp.completion.get()
  else
    feed '<C-x><C-o>'
  end
end

vim.api.nvim_create_autocmd('TextChangedI', {
  group = vim.api.nvim_create_augroup('completion-autotrigger', { clear = true }),
  callback = function(args)
    if vim.fn.pumvisible() == 1 or vim.fn.mode() ~= 'i' then
      return
    end
    local clients = vim.lsp.get_clients and vim.lsp.get_clients { bufnr = args.buf } or vim.lsp.buf_get_clients(args.buf)
    local can_complete = false
    for _, c in ipairs(clients) do
      if c.server_capabilities and c.server_capabilities.completionProvider then
        can_complete = true
        break
      end
    end
    if not can_complete then
      return
    end

    local col = vim.fn.col '.' - 1
    local before = vim.api.nvim_get_current_line():sub(1, col)
    if before:match '[%w_][%w_]$' or before:match '%.$' then
      trigger()
    end
  end,
})

-- ---------------------------------------------------------------------------
-- Menu border, matching the picker floats (BORDER and PickerBorder in core/picker.lua).
--
-- Neovim 0.12 has 'pumborder'. Before that the popup menu is not a window and cannot
-- have one, so we draw an empty bordered float exactly around it, one z-level below
-- (the menu is zindex 100). The menu paints over the float's interior and only the frame
-- shows. CompleteChanged fires every time the menu moves, resizes or refilters, so the
-- frame follows it. Windows cannot be touched under CompleteChanged's textlock, so the
-- redraw is scheduled and re-reads the geometry with pum_getpos() (empty once closed).
-- ---------------------------------------------------------------------------

local BORDER = 'single'
local WINHL = 'Normal:PickerNormal,NormalFloat:PickerNormal,FloatBorder:PickerBorder'

if pcall(function() return vim.o.pumborder end) then
  vim.o.pumborder = BORDER
else
  -- The 8-char form of BORDER, so individual sides can be blanked.
  local BORDER_CHARS = { '┌', '─', '┐', '│', '┘', '─', '└', '│' }
  local frame = { buf = nil, win = nil }

  local function close()
    if frame.win and vim.api.nvim_win_is_valid(frame.win) then
      vim.api.nvim_win_close(frame.win, true)
    end
    frame.win = nil
  end

  local function draw(ev)
    if vim.fn.mode() ~= 'i' or not ev.width or ev.width == 0 or ev.height == 0 then
      return close()
    end
    -- A float's row/col is its outer corner, border included, so step one cell up-left
    -- of the menu. The scrollbar is an extra column to the right of `width`. A menu
    -- flush against the screen's top or left edge has no room for that side, so it is
    -- left undrawn rather than letting Neovim shift the whole frame onto the menu.
    local chars = vim.deepcopy(BORDER_CHARS)
    local top, left = ev.row >= 1, ev.col >= 1
    if not top then
      chars[1], chars[2], chars[3] = '', '', ''
    end
    if not left then
      chars[1], chars[7], chars[8] = '', '', ''
    end
    local cfg = {
      relative = 'editor',
      row = top and ev.row - 1 or ev.row,
      col = left and ev.col - 1 or ev.col,
      width = ev.width + (ev.scrollbar and 1 or 0),
      height = ev.height,
      border = chars,
      style = 'minimal',
      focusable = false,
      zindex = 99,
      noautocmd = true,
    }
    if frame.win and vim.api.nvim_win_is_valid(frame.win) then
      cfg.noautocmd = nil
      vim.api.nvim_win_set_config(frame.win, cfg)
      return
    end
    if not (frame.buf and vim.api.nvim_buf_is_valid(frame.buf)) then
      frame.buf = vim.api.nvim_create_buf(false, true)
    end
    frame.win = vim.api.nvim_open_win(frame.buf, false, cfg)
    vim.wo[frame.win].winhighlight = WINHL
  end

  local function register(opts)
    vim.api.nvim_create_autocmd('CompleteChanged', vim.tbl_extend('force', opts, {
      callback = function()
        vim.schedule(function()
          draw(vim.fn.pum_getpos())
        end)
      end,
    }))
    vim.api.nvim_create_autocmd({ 'CompleteDone', 'InsertLeave' }, vim.tbl_extend('force', opts, {
      callback = function()
        vim.schedule(close)
      end,
    }))
  end

  -- Global, for <C-n>/<C-x> completion in any buffer.
  register { group = vim.api.nvim_create_augroup('completion-border', { clear = true }) }

  -- Buffer-local again from LspAttach (core/lsp.lua). On the restricted machine global
  -- augroups made here have been seen to vanish after startup (same as the keyword
  -- autotrigger), and buffer-local ones made at attach time survive. Doubling up is
  -- harmless: both redraw the same frame.
  M.attach_border = function(buf)
    if vim.b[buf].pum_border then
      return
    end
    vim.b[buf].pum_border = true
    register { buffer = buf }
  end
end

return M
