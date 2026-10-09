-- Highlight every occurrence of the word under the cursor, in the current window.
--
-- Works purely off 'iskeyword' and matchadd(), so it needs no LSP and works in any
-- buffer. Matches are window-local and only drawn for the visible lines, so the cost
-- is the same in a 10-line file as in a 100k-line one.
--
--   <leader>tw  toggle the highlight on/off
--
-- The highlight is a separate CursorWord group so 'hlsearch' results (higher matchadd
-- priority) still win where the two overlap.

local M = {}

-- Words shorter than this are not worth highlighting (i, x, a, ...).
local MIN_LEN = 2

-- Below 'hlsearch' (0) so an active search is never hidden by this.
local PRIORITY = -1

local enabled = true

---CursorWord links to LspReferenceText, so it matches what an LSP's document highlight
---would look like. `default` lets a colorscheme define its own CursorWord instead.
local function setup_highlight()
  vim.api.nvim_set_hl(0, 'CursorWord', { link = 'LspReferenceText', default = true })
end

---Remove this window's match, if any.
local function clear()
  local id = vim.w.cursorword_id
  if id then
    pcall(vim.fn.matchdelete, id)
    vim.w.cursorword_id = nil
    vim.w.cursorword = nil
  end
end

---The keyword under the cursor, or nil when the cursor is not on one. expand('<cword>')
---is not enough: it returns the NEXT keyword on the line when the cursor sits on
---whitespace or punctuation, which would highlight a word you are not on.
local function word_under_cursor()
  local col = vim.fn.col '.'
  local char = vim.fn.getline('.'):sub(col, col)
  if char == '' or vim.fn.match(char, '\\k') == -1 then
    return nil
  end
  local word = vim.fn.expand '<cword>'
  if #word < MIN_LEN then
    return nil
  end
  return word
end

local function update()
  if not enabled or vim.bo.buftype ~= '' then
    clear()
    return
  end

  local word = word_under_cursor()
  -- Same word as last time: leave the existing match alone (the common case while
  -- moving within a word, or between occurrences of it).
  if word and word == vim.w.cursorword then
    return
  end

  clear()
  if not word then
    return
  end
  -- \V = very nomagic so the word is literal; \< \> = whole-word only.
  local pattern = '\\V\\<' .. vim.fn.escape(word, '\\') .. '\\>'
  vim.w.cursorword_id = vim.fn.matchadd('CursorWord', pattern, PRIORITY)
  vim.w.cursorword = word
end

function M.toggle()
  enabled = not enabled
  if enabled then
    update()
  else
    -- Matches are per window, so clear them in every window of every tab.
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      vim.api.nvim_win_call(win, clear)
    end
  end
  vim.notify('Cursor word highlight ' .. (enabled and 'on' or 'off'))
end

setup_highlight()

local group = vim.api.nvim_create_augroup('user-cursorword', { clear = true })
vim.api.nvim_create_autocmd('ColorScheme', { group = group, callback = setup_highlight })
vim.api.nvim_create_autocmd({ 'CursorMoved', 'BufEnter', 'WinEnter', 'InsertLeave' }, {
  group = group,
  callback = update,
})
-- Hide while typing (the word is changing anyway) and when leaving a window, so only
-- the window you are in shows highlights.
vim.api.nvim_create_autocmd({ 'InsertEnter', 'WinLeave', 'BufLeave' }, {
  group = group,
  callback = clear,
})

vim.keymap.set('n', '<leader>tw', M.toggle, { desc = '[T]oggle cursor [W]ord highlight' })

return M
