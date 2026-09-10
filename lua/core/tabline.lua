-- Tabline for TAB PAGES (not buffers), with separators and no plugins.
--
--   1 models.py ▐ 2 main.py + ▌ 3 test_api.py
--                └─ selected tab, tapered into the bar at both ends
--                                              └─ thin divider between unselected tabs
--
-- Keeps the stock TabLine / TabLineSel / TabLineFill groups so your colorscheme drives
-- the colours. The only group added is TabLineSep, which must carry TabLineSel's
-- BACKGROUND as its foreground -- that is what turns the half-block into a taper rather
-- than a visible glyph.
--
-- U+2590 / U+258C fill the right / left half of a cell, and U+2502 is a thin bar. All
-- standard Unicode: no patched font.

local SEP = {
  before = '\u{2590}', -- ▐ closes the gap before the selected tab
  after = '\u{258C}', -- ▌ and after it
  divider = '\u{2502}', -- │ between two unselected tabs
}

---Resolve a highlight group, following links.
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

---TabLineSep = the selected tab's background, drawn as a foreground on the bar.
---Re-derived on every ColorScheme, since those clear user highlights.
---
---Not every colorscheme gives TabLineSel a background -- Neovim's stock one does not.
---With no block to continue, the half-blocks would render in the bar colour and be
---invisible, so fall back to a group that does have one, and failing that to TabLine's
---foreground, where the glyphs simply read as dividers.
local function sync_sep_highlight()
  local sel, fill = hl_get('TabLineSel'), hl_get('TabLineFill')
  -- A candidate is only useful if it DIFFERS from the bar background; picking one that
  -- matches leaves the glyph the same colour as what is behind it.
  local function usable(colour)
    return colour ~= nil and colour ~= fill.bg
  end

  local block_bg = usable(sel.bg) and sel.bg or nil
  if not block_bg then
    for _, name in ipairs({ 'Visual', 'PmenuSel', 'CursorLine', 'StatusLine' }) do
      local h = hl_get(name)
      if usable(h.bg) then
        block_bg = h.bg
        break
      end
    end
  end
  -- Last resort: TabLine's foreground, so the half-blocks at least read as dividers.
  vim.api.nvim_set_hl(0, 'TabLineSep', {
    fg = block_bg or hl_get('TabLine').fg or hl_get('Normal').fg,
    bg = fill.bg,
  })
end

function _G.tabline()
  local s = ''
  local current = vim.fn.tabpagenr()
  local last = vim.fn.tabpagenr('$')

  for i = 1, last do
    local buflist = vim.fn.tabpagebuflist(i)
    local bufnr = buflist[vim.fn.tabpagewinnr(i)]
    local name = vim.fn.bufname(bufnr)

    local label
    if vim.bo[bufnr].buftype == 'terminal' then
      label = '[terminal]'
    elseif name == '' then
      label = '[No Name]'
    else
      label = vim.fn.fnamemodify(name, ':t')
    end

    -- '+' if ANY buffer in the tab is modified, not just the visible one -- with splits
    -- that is the more useful signal.
    for _, b in ipairs(buflist) do
      if vim.bo[b].modified then
        label = label .. ' +'
        break
      end
    end

    -- A divider only between two UNSELECTED neighbours; next to the selected tab the
    -- tapers already do the separating and a divider there would double up.
    if i > 1 and i ~= current and i - 1 ~= current then
      s = s .. '%#TabLine#' .. SEP.divider
    end

    s = s .. '%' .. i .. 'T'
    if i == current then
      s = s .. '%#TabLineSep#' .. SEP.before
      s = s .. '%#TabLineSel# ' .. label:gsub('%%', '%%%%') .. ' '
      s = s .. '%#TabLineSep#' .. SEP.after
    else
      s = s .. '%#TabLine# ' .. label:gsub('%%', '%%%%') .. ' '
    end
  end

  return s .. '%#TabLineFill#%T'
end

vim.o.tabline = '%!v:lua.tabline()'
vim.o.showtabline = 2

sync_sep_highlight()
vim.api.nvim_create_autocmd('ColorScheme', {
  group = vim.api.nvim_create_augroup('user-tabline', { clear = true }),
  callback = sync_sep_highlight,
})
