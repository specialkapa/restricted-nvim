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
--
-- Deliberately NOT 'fuzzy' or 'popup'. ty answers each request with thousands of items.
-- With 'fuzzy', vim.lsp.completion calls vim.fn.matchfuzzy() once per item on the main
-- thread; with 'popup', moving through the menu sends a completionItem/resolve for every
-- entry. Together they made typing stall on the VDI (0.11.4); removing both fixed it.
-- Docs for the selected item are still available after accepting, via K.
vim.opt.completeopt = { 'menu', 'menuone', 'noinsert' }

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

-- <C-h> jumps back through snippet placeholders, standing in for LuaSnip. <C-l> (expand or
-- jump forward) lives in core/snippets.lua. vim.snippet is 0.11-era; on older builds the
-- LSP client cannot expand snippets at all.
if vim.snippet then
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
-- Once a word is 3 keyword characters long, and you then pause for DELAY_MS, it opens:
--   * <C-x><C-o> (the LSP omnifunc) in a buffer with a server that completes
--   * <C-n> (words from this and the other loaded buffers, per 'complete') anywhere else
-- Every key typed in the meantime restarts the wait, so typing a word quickly sends no
-- request at all until you stop. It fires at most once per word: if the menu closes
-- because nothing matches, it stays closed (<C-Space> asks again). Each request makes
-- the server send its whole list -- thousands of items with ty -- and Neovim converts
-- and filters all of them on the main thread, so asking once per word matters.
-- After a `/` ending a path that starts `/`, `./`, `../` or `~/` it opens <C-x><C-f>
-- (file names, relative to the cwd) in any buffer, LSP or not.
--
-- Buffer-local. A global augroup made here vanished after startup on the restricted
-- machine; buffer-local autocmds made at attach time survive. So it is attached both
-- from LspAttach (core/lsp.lua) and from InsertEnter below, whichever comes first.
--
-- Once the menu is open Neovim filters it natively as you keep typing.
-- ---------------------------------------------------------------------------

-- cmp-buffer's reach: this buffer, buffers in other windows, other loaded buffers. The
-- default also scans unloaded buffers (read from disk) and tags, too slow per keystroke.
vim.opt.complete = '.,w,b'

local MIN_CHARS = 3
local DELAY_MS = 90

local timer = (vim.uv or vim.loop).new_timer()

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
      timer:stop() -- a new key cancels a pending trigger
      if not M.auto or vim.fn.pumvisible() == 1 or vim.fn.mode() ~= 'i' then
        return
      end
      local lnum = vim.fn.line '.'
      local before = vim.api.nvim_get_current_line():sub(1, vim.fn.col '.' - 1)
      -- A <C-n> that finds nothing puts the text back, which fires TextChangedI again;
      -- without this it would feed <C-n> forever and lock up the editor.
      local key = lnum .. ':' .. before
      if vim.b[buf].kw_last == key then
        return
      end
      vim.b[buf].kw_last = key

      -- Paths and `.` open straight away, as before.
      -- Checked before `accepted`: accepting a directory should open the next level.
      if ends_in_path(before) then
        return feed '<C-x><C-f>'
      end
      local lsp = lsp_completes(buf) or vim.b[buf].kw_omni
      -- `.` is left to the native autotrigger when there is one. kw_omni marks a buffer
      -- whose 'omnifunc' is not LSP (core.hive in SQL), so `.` is ours there.
      if lsp and not accepted and (vim.b[buf].kw_omni or not has_native) and before:match '%.$' then
        return feed '<C-x><C-o>'
      end

      -- Words: once per word, identified by its line and start column.
      local word = before:match '[%w_]+$'
      if not word or #word < MIN_CHARS then
        return
      end
      local word_key = lnum .. ':' .. (#before - #word)
      if accepted then
        vim.b[buf].kw_word = word_key -- the word you just accepted is done
        return
      end
      if vim.b[buf].kw_word == word_key then
        return
      end
      timer:start(
        DELAY_MS,
        0,
        vim.schedule_wrap(function()
          -- Still typing in the same word, in the same buffer, with no menu open?
          if vim.api.nvim_get_current_buf() ~= buf or vim.fn.mode() ~= 'i' or vim.fn.pumvisible() == 1 then
            return
          end
          local now = vim.api.nvim_get_current_line():sub(1, vim.fn.col '.' - 1)
          local w = now:match '[%w_]+$'
          if not w or #w < MIN_CHARS or vim.fn.line '.' .. ':' .. (#now - #w) ~= word_key then
            return
          end
          vim.b[buf].kw_word = word_key
          feed(lsp and '<C-x><C-o>' or '<C-n>')
        end)
      )
    end,
  })
end

vim.api.nvim_create_autocmd('InsertEnter', {
  group = vim.api.nvim_create_augroup('completion-autotrigger', { clear = true }),
  callback = function(args)
    M.attach_autotrigger(args.buf)
  end,
})

-- ---------------------------------------------------------------------------
-- Turning it off for a while: <leader>ta / :AutocompleteToggle. Every buffer, this
-- session only. Manual completion (<C-Space>, <C-x><C-o>, <C-n>) keeps working.
-- ---------------------------------------------------------------------------

M.auto = true -- read by the LspAttach handler in core/lsp.lua for buffers attached later

---Re-register the buffer's completing clients with vim.lsp.completion, with or without its
---autotrigger on `.`. All are disabled first: the autotrigger autocmds belong to the
---buffer and are only rebuilt once its last client is gone.
local function set_native(buf, on)
  local clients = vim.lsp.get_clients { bufnr = buf, method = 'textDocument/completion' }
  for _, c in ipairs(clients) do
    pcall(vim.lsp.completion.enable, false, c.id, buf)
  end
  for _, c in ipairs(clients) do
    pcall(vim.lsp.completion.enable, true, c.id, buf, { autotrigger = on })
  end
end

M.toggle = function()
  M.auto = not M.auto
  if has_native then
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(buf) then
        set_native(buf, M.auto)
      end
    end
  end
  vim.notify('Autocompletion ' .. (M.auto and 'on' or 'off'))
end

vim.keymap.set('n', '<leader>ta', M.toggle, { desc = '[T]oggle [A]utocompletion' })
vim.api.nvim_create_user_command('AutocompleteToggle', M.toggle, { desc = 'Toggle autocompletion' })

return M
