-- Autocompletion with no plugins.
--
-- On Neovim 0.11+ the work is done by vim.lsp.completion.enable(), called from the
-- LspAttach handler in core/lsp.lua. This file supplies the surrounding ergonomics:
-- 'completeopt', navigation keys and snippet jumps.
--
-- Keymaps mirror the nvim-cmp setup on the main machine so muscle memory carries across.

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
