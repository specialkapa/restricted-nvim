-- Autocompletion with no plugins.
--
-- On Neovim 0.11+ the work is done by vim.lsp.completion.enable(), called from the
-- LspAttach handler in core/lsp.lua. This file supplies the surrounding ergonomics:
-- 'completeopt', navigation keys and snippet jumps.
--
-- Keymaps mirror the nvim-cmp setup on the main machine so muscle memory carries across.

local M = {}

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
-- Autotrigger, standing in for cmp's nvim_lsp + buffer + path sources.
--
-- vim.lsp.completion's own `autotrigger` fires ONLY on the trigger characters the server
-- advertises -- for python that is basically `.`, so typing a bare identifier never opens
-- the menu. nvim-cmp triggered on any keyword character; this restores that. It doubles
-- as the autotrigger for Neovim < 0.11, where 'omnifunc' is the only route.
--
-- After two keyword characters it opens:
--   * <C-x><C-o> (the LSP omnifunc) in a buffer with a server that completes
--   * <C-n> (words from this and the other loaded buffers, per 'complete') anywhere else
-- After a `/` ending a path that starts `/`, `./`, `../` or `~/` it opens <C-x><C-f>
-- (file names, relative to the cwd) in any buffer, LSP or not.
--
-- Buffer-local. A global augroup made here vanished after startup on the restricted
-- machine; buffer-local autocmds made at attach time survive. So it is attached both
-- from LspAttach (core/lsp.lua) and from InsertEnter below, whichever comes first.
--
-- Once the menu is open Neovim filters it natively as you keep typing, so this fires at
-- most once per word rather than on every keystroke.
-- ---------------------------------------------------------------------------

-- cmp-buffer's reach: this buffer, buffers in other windows, other loaded buffers. The
-- default also scans unloaded buffers (read from disk) and tags, too slow per keystroke.
vim.opt.complete = '.,w,b'

local function lsp_completes(buf)
  return #vim.lsp.get_clients { bufnr = buf, method = 'textDocument/completion' } > 0
end

-- `src/`, not `a/` -- so division in code never opens the file menu.
local function ends_in_path(before)
  local word = before:match '[^%s\'"`(=,]*$'
  return word:match '/$' and (word:match '^%.?%.?/' or word:match '^~/') ~= nil
end

M.attach_autotrigger = function(buf)
  local bt = vim.bo[buf].buftype
  if vim.b[buf].kw_autotrigger or (bt ~= '' and bt ~= 'acwrite') then
    return
  end
  vim.b[buf].kw_autotrigger = true
  -- Accepting an entry changes the text too; without this the word you just accepted
  -- would reopen the menu on itself.
  vim.api.nvim_create_autocmd('CompleteDone', {
    buffer = buf,
    callback = function()
      if vim.v.event.reason == 'accept' then
        vim.b[buf].kw_accepted = true
      end
    end,
  })
  vim.api.nvim_create_autocmd('TextChangedI', {
    buffer = buf,
    callback = function()
      local accepted = vim.b[buf].kw_accepted
      vim.b[buf].kw_accepted = nil
      if vim.fn.pumvisible() == 1 or vim.fn.mode() ~= 'i' then
        return
      end
      local before = vim.api.nvim_get_current_line():sub(1, vim.fn.col '.' - 1)
      -- A <C-n> that finds nothing puts the text back, which fires TextChangedI again;
      -- without this it would feed <C-n> forever and lock up the editor.
      local key = vim.fn.line '.' .. ':' .. before
      if vim.b[buf].kw_last == key then
        return
      end
      vim.b[buf].kw_last = key
      -- Checked before `accepted`: accepting a directory should open the next level.
      if ends_in_path(before) then
        feed '<C-x><C-f>'
      elseif accepted then
        return
      elseif lsp_completes(buf) or vim.b[buf].kw_omni then
        -- `.` is left to the native autotrigger when there is one. kw_omni marks a
        -- buffer whose 'omnifunc' is not LSP (core.hive in SQL), so `.` is ours there.
        if before:match '[%w_][%w_]$' or ((vim.b[buf].kw_omni or not has_native) and before:match '%.$') then
          feed '<C-x><C-o>'
        end
      elseif before:match '[%w_][%w_]$' then
        feed '<C-n>'
      end
    end,
  })
end

vim.api.nvim_create_autocmd('InsertEnter', {
  group = vim.api.nvim_create_augroup('completion-autotrigger', { clear = true }),
  callback = function(args)
    M.attach_autotrigger(args.buf)
  end,
})

return M
