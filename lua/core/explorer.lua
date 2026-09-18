-- Reveal the current file in netrw.
--
-- `:Lexplore` opens the sidebar at the CWD; `:Lexplore %:p:h` opens it at the current
-- file's directory. Neither positions the cursor on the file itself -- it lands on '../'
-- -- so this adds the search that actually reveals it.
--
--   <leader>e  toggle the sidebar at the CWD
--   <leader>E  reveal the current file in the sidebar
--
-- Both go through the same WIDTH below, so they cannot drift apart.

local M = {}

-- Sidebar width, in netrw's own g:netrw_winsize convention:
--   negative -> absolute columns   (-35 = exactly 35 columns)
--   positive -> percent of screen  (25  = a quarter of the width)
-- netrw's default is 50%, which is what `:Lex` alone gives you.
local WIDTH = -35

vim.g.netrw_winsize = WIDTH

---Is the netrw sidebar open in this tab? netrw records its buffer in t:netrw_lexbufnr.
local function lex_open()
  local bufnr = vim.t.netrw_lexbufnr
  return bufnr ~= nil and vim.fn.bufwinnr(bufnr) ~= -1
end

---Move the cursor onto `name` in the netrw listing. Netrw indents entries in tree view
---and pads them in other list styles, so match the bare name rather than a whole line.
local function focus_entry(name)
  if name == '' then
    return
  end
  vim.fn.cursor(1, 1)
  -- \V = very nomagic, so a filename containing '.' or '-' is matched literally.
  vim.fn.search('\\V' .. vim.fn.escape(name, '\\'), 'cW')
end

---Open the netrw sidebar at the current file's directory, cursor on that file.
function M.reveal()
  local path = vim.api.nvim_buf_get_name(0)
  if path == '' or vim.bo.buftype ~= '' then
    -- No file to reveal (scratch, terminal, netrw itself): just open at the CWD.
    if not lex_open() then
      vim.cmd 'Lexplore'
    end
    return
  end

  local dir = vim.fs.dirname(path)
  local name = vim.fn.fnamemodify(path, ':t')

  -- :Lexplore toggles, so an already-open sidebar would close instead of re-rooting.
  if lex_open() then
    vim.cmd 'Lexplore'
  end
  vim.cmd('Lexplore ' .. vim.fn.fnameescape(dir))

  -- Lexplore leaves the cursor in the netrw window; reveal the file there.
  if vim.bo.filetype == 'netrw' then
    focus_entry(name)
  end
end

---Toggle the sidebar at the CWD -- the plain `:Lexplore` behaviour, but going through
---this module so it picks up WIDTH along with everything else.
function M.toggle()
  vim.cmd 'Lexplore'
end

vim.keymap.set('n', '<leader>e', M.toggle, { desc = 'Toggle file [e]xplorer' })
vim.keymap.set('n', '<leader>E', M.reveal, { desc = 'R[E]veal current file in netrw' })

return M
