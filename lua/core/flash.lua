-- Jump anywhere on screen by typing a few characters and then a label. The parts of
-- flash.nvim this config used, on the same keys.
--
--   s       type characters, then the label shown after the match you want. Searches
--           every window in the tab page from normal mode, the current one otherwise.
--           <CR> takes the nearest match, <BS> deletes a character, <Esc> cancels
--   S       pick a syntax node around the cursor (its label is at both ends) and select
--           it. ; / , grow / shrink the highlighted one, <CR> selects that
--   r       operator-pending: remote. `yr` + characters + label + a motion, e.g.
--           `yr<label>iw`, yanks a word anywhere on screen and puts the cursor back
--   R       visual / operator-pending: type characters, then pick a node around a match
--   <C-s>   while typing a / or ? search: toggle labels on the matches; type one to jump
--   f F t T to a character, across lines. The matches stay lit afterwards, so f / F
--           (or ; / ,) again go to the next / previous one; any other key ends that.
--           ; and , also repeat the last one later on
--
-- Nodes come from treesitter when the buffer has a parser, otherwise from an LSP server
-- with textDocument/selectionRange. Neovim bundles no python parser, so in python
-- buffers S and R only work if the server has it.
--
-- `.` repeats an operator done with s, S, R, f, F, t or T: same characters, same label.
-- Labels are handed out nearest first, so that is the same place relative to the cursor.

local M = {}

local api = vim.api

local LABELS = 'asdfghjklqwertyuiopzxcvbnm'
local PRIORITY = 10000 -- above treesitter / semantic token highlights

local ESC = vim.keycode '<Esc>'
local CR = vim.keycode '<CR>'
local BS = vim.keycode '<BS>'

---Matches, the current node and labels only change the foreground, so the text keeps
---its background and stands out from the grey backdrop by colour alone. cterm colours
---are for when 'termguicolors' is off.
local function setup_highlight()
  local function fg(name, gui, cterm, bold)
    api.nvim_set_hl(0, name, { fg = gui, ctermfg = cterm, bold = bold, cterm = bold and { bold = true } or nil, default = true })
  end
  api.nvim_set_hl(0, 'FlashBackdrop', { link = 'Comment', default = true })
  fg('FlashMatch', '#7dcfff', 117) -- cyan
  fg('FlashCurrent', '#ff9e64', 215, true) -- orange
  fg('FlashLabel', '#ff007c', 198, true) -- pink
end

-- One namespace per window, scoped to it, so a buffer shown in two windows only gets
-- the marks meant for each. Without nvim__ns_set they fall back to a shared one.
local NS = api.nvim_create_namespace 'flash'
local spaces = {}

local function ns_of(win)
  if not spaces[win] then
    local ns = api.nvim_create_namespace('flash.' .. win)
    spaces[win] = pcall(api.nvim__ns_set, ns, { wins = { win } }) and ns or NS
  end
  return spaces[win]
end

local function clear(wins)
  for _, win in ipairs(wins) do
    if api.nvim_win_is_valid(win) then
      api.nvim_buf_clear_namespace(api.nvim_win_get_buf(win), ns_of(win), 0, -1)
    end
  end
end

---Draw items: { win, row, col, erow, ecol, hl?, label?, both? }. Rows are 1-based, cols
---0-based bytes with ecol exclusive. The label overlays the character after the item,
---or with `both` sits inline at its start and end.
local function render(wins, items, backdrop)
  clear(wins)
  for _, win in ipairs(wins) do
    if backdrop ~= false then
      local buf = api.nvim_win_get_buf(win)
      local top, bot = vim.fn.line('w0', win), vim.fn.line('w$', win)
      local last = api.nvim_buf_get_lines(buf, bot - 1, bot, false)[1] or ''
      api.nvim_buf_set_extmark(buf, ns_of(win), top - 1, 0, {
        end_row = bot - 1,
        end_col = #last,
        hl_group = 'FlashBackdrop',
        priority = PRIORITY,
        strict = false,
      })
    end
  end
  for _, it in ipairs(items) do
    local buf, ns = api.nvim_win_get_buf(it.win), ns_of(it.win)
    if it.hl and (it.erow > it.row or it.ecol > it.col) then
      api.nvim_buf_set_extmark(buf, ns, it.row - 1, it.col, {
        end_row = it.erow - 1,
        end_col = it.ecol,
        hl_group = it.hl,
        priority = PRIORITY + 1,
        strict = false,
      })
    end
    if it.label then
      local text = { { it.label, 'FlashLabel' } }
      if it.both then
        api.nvim_buf_set_extmark(buf, ns, it.row - 1, it.col, { virt_text = text, virt_text_pos = 'inline', priority = PRIORITY + 2, strict = false })
      end
      api.nvim_buf_set_extmark(buf, ns, it.erow - 1, it.ecol, {
        virt_text = text,
        virt_text_pos = it.both and 'inline' or 'overlay',
        priority = PRIORITY + 2,
        strict = false,
      })
    end
  end
end

---The next key, after drawing. nil for <Esc>, <C-c> and keys like <Left>.
local function getkey()
  vim.cmd.redraw()
  local ok, key = pcall(vim.fn.getcharstr)
  if not ok or key == ESC or key == '\3' or (key:byte() == 0x80 and key ~= BS) then
    return nil
  end
  return key
end

---Abandon the pending operator, so a cancelled `cs` does not drop into insert mode.
local function cancel()
  api.nvim_feedkeys(vim.keycode '<C-\\><C-n>', 'nx', false)
  api.nvim_feedkeys(ESC, 'n', false)
end

local function pending()
  return api.nvim_get_mode().mode:sub(1, 2) == 'no'
end

-- `.` replays an operator by calling the mapping again. It must not prompt then, but
-- reuse what was typed last time (flash.nvim's trick: watch for the `.` key).
local repeating = false
local last = {} -- jump / node / search: { pattern, label } or a node index

vim.on_key(function(key)
  if key == '.' and vim.fn.reg_executing() == '' and vim.fn.reg_recording() == '' then
    repeating = true
    vim.schedule(function()
      repeating = false
    end)
  end
end, api.nvim_create_namespace 'flash.repeat')

---The current window, plus with `all` the other non-floating ones in the tab page.
local function windows(all)
  local cur = api.nvim_get_current_win()
  local out = { cur }
  if all then
    for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
      if win ~= cur and api.nvim_win_get_config(win).relative == '' then
        out[#out + 1] = win
      end
    end
  end
  return out
end

---`str` as a literal pattern, with 'ignorecase' and 'smartcase' applied.
local function literal(str)
  local ignore = vim.o.ignorecase and not (vim.o.smartcase and str:find '%u')
  return (ignore and '\\c' or '\\C') .. '\\V' .. vim.fn.escape(str, '\\')
end

---A / pattern with 'smartcase' applied, which matchbufline() does not do by itself.
local function with_case(pat)
  if vim.o.ignorecase and vim.o.smartcase and not pat:find '\\[cC]' and (pat:gsub('\\.', '')):find '%u' then
    return '\\C' .. pat
  end
  return pat
end

---Drop every label that some match of `pat` in the current buffer is followed by, so
---typing a label can never also mean one more character of the pattern.
local function usable(labels, pat)
  while labels ~= '' do
    local ok, pos = pcall(vim.fn.searchpos, '\\%(' .. pat .. '\\)\\m\\zs[' .. labels .. ']', 'cnw', 0, 200)
    if not ok then
      return ''
    end
    if pos[1] == 0 then
      return labels
    end
    local ch = vim.fn.getline(pos[1]):sub(pos[2], pos[2]):lower()
    local before = #labels
    labels = labels:gsub(ch, '')
    if #labels == before then
      return ''
    end
  end
  return labels
end

---Matches of `pat` on the visible lines of each window, current window first and
---nearest the cursor first, plus the labels that are safe to use with them. In a
---closed fold only the first match counts.
local function find(wins, pat)
  local cursor = api.nvim_win_get_cursor(wins[1])
  local cols = vim.o.columns
  local items, labels = {}, LABELS
  for order, win in ipairs(wins) do
    api.nvim_win_call(win, function()
      local ok, found = pcall(vim.fn.matchbufline, api.nvim_get_current_buf(), pat, vim.fn.line 'w0', vim.fn.line 'w$')
      local folds = {}
      for _, m in ipairs(ok and found or {}) do
        local fold = vim.fn.foldclosed(m.lnum)
        if fold == -1 or not folds[fold] then
          folds[fold] = true
          local dist = order == 1 and math.abs((m.lnum - cursor[1]) * cols + m.byteidx - cursor[2]) or m.lnum * cols + m.byteidx
          items[#items + 1] = {
            win = win,
            row = m.lnum,
            col = m.byteidx,
            erow = m.lnum,
            ecol = m.byteidx + #m.text,
            hl = 'FlashMatch',
            order = order,
            dist = dist,
          }
        end
      end
      labels = usable(labels, pat)
    end)
  end
  table.sort(items, function(a, b)
    if a.order ~= b.order then
      return a.order < b.order
    end
    return a.dist < b.dist
  end)
  return items, labels
end

---Give items[i] the i-th label. Returns the items by label.
local function assign(items, labels)
  local by_label = {}
  for i, it in ipairs(items) do
    local l = labels:sub(i, i)
    if l == '' then
      break
    end
    it.label = l
    by_label[l] = it
  end
  return by_label
end

---Read keys into a pattern until one is a label. items_for(pattern) returns the items
---to show and those of them by label. Returns the item picked and the pattern, or nil
---when cancelled or when nothing matches any more.
local function prompt(wins, items_for)
  local pattern, items, by_label = '', {}, {}
  local ok, picked = pcall(function()
    while true do
      render(wins, items)
      local key = getkey()
      if not key then
        return
      elseif key == CR then
        return items[1] and items[1].label and items[1]
      elseif key == BS then
        if pattern == '' then
          return
        end
        pattern = vim.fn.strcharpart(pattern, 0, vim.fn.strchars(pattern) - 1)
      elseif by_label[key] then
        return by_label[key]
      else
        pattern = pattern .. key
      end
      items, by_label = {}, {}
      if pattern ~= '' then
        items, by_label = items_for(pattern)
        if #items == 0 then
          return
        end
      end
    end
  end)
  clear(wins)
  if not ok then
    error(picked)
  end
  return picked, pattern
end

---Move to an item's start. With an operator pending, start Visual first: the operator
---then covers cursor..target inclusive (`ds` + label deletes through the match start).
local function jump_to(it)
  local mode = api.nvim_get_mode().mode
  local op = mode:sub(1, 2) == 'no'
  if mode == 'n' then
    vim.cmd "normal! m'"
  end
  if it.win ~= api.nvim_get_current_win() then
    api.nvim_set_current_win(it.win)
  end
  if op then
    vim.cmd 'normal! v'
  end
  api.nvim_win_set_cursor(it.win, { it.row, it.col })
  if not op then
    vim.cmd 'normal! zv'
  end
end

---Select an item charwise, from its start through the character before ecol.
local function select(it)
  if api.nvim_get_mode().mode:match '^[vV\22]' then
    vim.cmd('normal! ' .. ESC)
  end
  vim.cmd "normal! m'"
  api.nvim_win_set_cursor(it.win, { it.row, it.col })
  vim.cmd 'normal! v'
  api.nvim_win_set_cursor(it.win, { it.erow, math.max(it.ecol - 1, 0) })
end

local function labelled(wins)
  return function(pattern)
    local items, labels = find(wins, literal(pattern))
    return items, assign(items, labels)
  end
end

function M.jump()
  local mode = api.nvim_get_mode().mode
  local op = mode:sub(1, 2) == 'no'
  local wins = windows(mode == 'n')
  local items_for = labelled(wins)

  if op and repeating and last.jump then
    local _, by_label = items_for(last.jump.pattern)
    local it = by_label[last.jump.label]
    if it then
      return jump_to(it)
    end
    return cancel()
  end

  local it, pattern = prompt(wins, items_for)
  if not it then
    return op and cancel()
  end
  if op then
    last.jump = { pattern = pattern, label = it.label }
  end
  jump_to(it)
end

---Remote operator: pick a place anywhere on screen, run the pending operator there
---with a motion typed next, then go back to where you were.
function M.remote()
  local op, reg = vim.v.operator, vim.v.register
  local from = api.nvim_get_current_win()
  local wins = windows(true)
  local views = {}
  for _, win in ipairs(wins) do
    views[win] = api.nvim_win_call(win, vim.fn.winsaveview)
  end

  local it = prompt(wins, labelled(wins))
  cancel()
  if not it then
    return
  end

  local function restore()
    for win, view in pairs(views) do
      if api.nvim_win_is_valid(win) then
        api.nvim_win_call(win, function()
          vim.fn.winrestview(view)
        end)
      end
    end
    if api.nvim_win_is_valid(from) then
      api.nvim_set_current_win(from)
    end
  end

  vim.schedule(function()
    api.nvim_set_current_win(it.win)
    api.nvim_win_set_cursor(it.win, { it.row, it.col })
    -- Restore once the operator is done: when operator-pending mode ends, or for `c`,
    -- when the insert it starts ends.
    local au
    au = api.nvim_create_autocmd('ModeChanged', {
      callback = function()
        if vim.v.event.old_mode:sub(1, 2) ~= 'no' then
          return
        end
        api.nvim_del_autocmd(au)
        if vim.v.event.new_mode == 'i' then
          api.nvim_create_autocmd('InsertLeave', { once = true, callback = vim.schedule_wrap(restore) })
        else
          vim.schedule(restore)
        end
      end,
    })
    api.nvim_feedkeys('"' .. reg .. op, 'n', false)
  end)
end

---Line `row` (1-based) of buf.
local function getline(buf, row)
  return api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or ''
end

---Ranges around each position, innermost first, as { srow, scol, erow, ecol } (0-based,
---end exclusive, like TSNode:range()). nil when the buffer has no parser.
local function ts_ranges(buf, positions)
  local ok, parser = pcall(vim.treesitter.get_parser, buf, nil, { error = false })
  if not ok or not parser then
    return nil
  end
  parser:parse(true)
  local out = {}
  for i, p in ipairs(positions) do
    local list = {}
    local node = parser:named_node_for_range({ p[1] - 1, p[2], p[1] - 1, p[2] }, { ignore_injections = false })
    while node do
      list[#list + 1] = { node:range() }
      node = node:parent()
    end
    out[i] = list
  end
  return out
end

---The same from textDocument/selectionRange. nil when no server has it.
local function lsp_ranges(buf, positions)
  local client = vim.lsp.get_clients({ bufnr = buf, method = 'textDocument/selectionRange' })[1]
  if not client then
    return nil
  end
  local enc = client.offset_encoding
  local params = { textDocument = { uri = vim.uri_from_bufnr(buf) }, positions = {} }
  for i, p in ipairs(positions) do
    local line = getline(buf, p[1])
    params.positions[i] = { line = p[1] - 1, character = vim.str_utfindex(line, enc, math.min(p[2], #line), false) }
  end
  local res = client:request_sync('textDocument/selectionRange', params, 1000, buf)
  if not (res and res.result) then
    return nil
  end
  local function byte(pos)
    return vim.str_byteindex(getline(buf, pos.line + 1), enc, pos.character, false)
  end
  local out = {}
  for i, sel in ipairs(res.result) do
    local list = {}
    while sel do
      local r = sel.range
      list[#list + 1] = { r.start.line, byte(r.start), r['end'].line, byte(r['end']) }
      sel = sel.parent
    end
    out[i] = list
  end
  return out
end

---Node items around each position in win, innermost first, duplicates dropped. nil when
---neither treesitter nor the LSP can say.
local function nodes(win, positions)
  local buf = api.nvim_win_get_buf(win)
  local ranges = ts_ranges(buf, positions) or lsp_ranges(buf, positions)
  if not ranges then
    return nil
  end
  local count = api.nvim_buf_line_count(buf)
  local out, seen = {}, {}
  for i, list in ipairs(ranges) do
    out[i] = {}
    for _, r in ipairs(list) do
      local srow, scol, erow, ecol = r[1] + 1, r[2], r[3] + 1, r[4]
      -- An end at column 0 of the next line (or past the last one) is the end of this one.
      if erow > count or (ecol == 0 and erow > srow) then
        erow = math.min(erow - 1, count)
        ecol = #getline(buf, erow)
      end
      local id = table.concat({ srow, scol, erow, ecol }, ':')
      if not seen[id] then
        seen[id] = true
        table.insert(out[i], { win = win, row = srow, col = scol, erow = erow, ecol = ecol, both = true })
      end
    end
  end
  return out
end

local function no_nodes()
  vim.notify('flash: no treesitter parser or LSP selectionRange for this buffer', vim.log.levels.WARN)
end

function M.treesitter()
  local op = pending()
  local win = api.nvim_get_current_win()
  local list = nodes(win, { api.nvim_win_get_cursor(win) })
  list = list and list[1]
  if not list or #list == 0 then
    no_nodes()
    return op and cancel()
  end
  assign(list, LABELS)

  if op and repeating and last.node then
    return select(list[math.min(last.node, #list)])
  end

  local current, picked = 1, nil
  local ok, err = pcall(function()
    while true do
      for i, n in ipairs(list) do
        n.hl = i == current and 'FlashCurrent' or nil
      end
      render({ win }, list)
      local key = getkey()
      if key == ';' then
        current = math.min(current + 1, #list)
      elseif key == ',' then
        current = math.max(current - 1, 1)
      elseif key == CR then
        picked = current
        return
      else
        for i, n in ipairs(list) do
          if n.label == key then
            picked = i
          end
        end
        return
      end
    end
  end)
  clear { win }
  if not ok then
    error(err)
  end
  if not picked then
    return op and cancel()
  end
  if op then
    last.node = picked
  end
  select(list[picked])
end

---Type characters, then pick a node around any of their matches in this window.
function M.treesitter_search()
  local op = pending()
  local win = api.nvim_get_current_win()
  if not nodes(win, { api.nvim_win_get_cursor(win) }) then
    no_nodes()
    return op and cancel()
  end

  local function items_for(pattern)
    local pat = literal(pattern)
    local found, labels = find({ win }, pat)
    local positions = {}
    for i, m in ipairs(found) do
      positions[i] = { m.row, m.col }
    end
    local items, seen = {}, {}
    for _, list in ipairs(#positions > 0 and nodes(win, positions) or {}) do
      for _, n in ipairs(list) do
        local id = table.concat({ n.row, n.col, n.erow, n.ecol }, ':')
        if not seen[id] then
          seen[id] = true
          items[#items + 1] = n
        end
      end
    end
    local by_label = assign(items, labels)
    vim.list_extend(items, found) -- lit, but not labelled
    return items, by_label
  end

  if op and repeating and last.search then
    local _, by_label = items_for(last.search.pattern)
    local it = by_label[last.search.label]
    if it then
      return select(it)
    end
    return cancel()
  end

  local it, pattern = prompt({ win }, items_for)
  if not it then
    return op and cancel()
  end
  if op then
    last.search = { pattern = pattern, label = it.label }
  end
  select(it)
end

-- Labels on / and ? matches, toggled with <C-s> while typing the search. Typing a label
-- leaves the search (keeping it in @/ for n and N) and jumps to that match.
local search = { on = false }

local function search_update()
  if not (search.on and vim.fn.getcmdtype():match '[/?]') then
    return
  end
  local win = api.nvim_get_current_win()
  local pat = vim.fn.getcmdline()
  local prev = search.prev
  local key = pat:sub(-1)
  if prev and #pat == #prev.pattern + 1 and pat:sub(1, -2) == prev.pattern and prev.by_label[key] then
    search.target = prev.by_label[key]
    search.target.pattern = prev.pattern
    search.target.forward = vim.fn.getcmdtype() == '/'
    api.nvim_feedkeys(ESC, 'n', false)
    return
  end
  local items, by_label = {}, {}
  if pat ~= '' then
    items, by_label = find({ win }, with_case(pat))
    by_label = assign(items, by_label)
  end
  search.prev = { pattern = pat, by_label = by_label }
  search.win = win
  render({ win }, items, false)
  vim.cmd.redraw()
end

local function search_leave()
  if search.win then
    clear { search.win }
  end
  search.prev, search.win = nil, nil
  local it = search.target
  search.target = nil
  if it then
    vim.schedule(function()
      vim.fn.setreg('/', it.pattern)
      vim.fn.histadd('search', it.pattern)
      vim.v.searchforward = it.forward and 1 or 0
      jump_to(it)
    end)
  end
end

function M.toggle()
  search.on = not search.on
  if search.on then
    search_update()
  else
    search_leave()
    vim.cmd.redraw()
  end
end

-- f / F / t / T. `char` is the last one: { char, key }.
local char = nil

local function swapcase(k)
  return k == k:lower() and k:upper() or k:lower()
end

---Where the count-th c after (forward) or before the cursor is, over as many lines as
---needed. With `skip`, one right next to the cursor does not count: what a repeated t / T
---needs to move on from it (as with 'cpoptions' without ;).
local function find_char(c, forward, skip, count)
  local row, col = unpack(api.nvim_win_get_cursor(0))
  if forward then
    local from = col + (skip and 2 or 1)
    for r = row, api.nvim_buf_line_count(0) do
      local line = getline(0, r)
      local s = line:find(c, from + 1, true)
      while s do
        count = count - 1
        if count == 0 then
          return r, s - 1
        end
        s = line:find(c, s + 1, true)
      end
      from = 0
    end
  else
    local before = col - (skip and 1 or 0)
    for r = row, 1, -1 do
      local line, hits = getline(0, r), {}
      local s = line:find(c, 1, true)
      while s and (not before or s - 1 < before) do
        hits[#hits + 1] = s - 1
        s = line:find(c, s + 1, true)
      end
      for i = #hits, 1, -1 do
        count = count - 1
        if count == 0 then
          return r, hits[i]
        end
      end
      before = nil
    end
  end
end

---Do the motion `key` for the last character. false when there is no such match.
---`again` for ; , and the loop, so t / T move on from a match right next to the cursor.
local function char_move(key, count, again)
  local forward, till = key == 'f' or key == 't', key:lower() == 't'
  local row, col = find_char(char.char, forward, till and again, count)
  if not row then
    return false
  end
  if till and forward then -- the character before it, maybe the end of the line above
    if col > 0 then
      local line = getline(0, row)
      col = col - 1 + vim.str_utf_start(line, col)
    else
      row = row - 1
      col = math.max(#getline(0, row) - 1, 0)
    end
  elseif till then -- the one after it, maybe the start of the line below
    col = col + #char.char
    if col >= #getline(0, row) and row < api.nvim_buf_line_count(0) then
      row, col = row + 1, 0
    end
  end
  -- Forward f and t are inclusive, so with an operator go through Visual (see jump_to).
  -- Backward ones are exclusive, which a plain cursor move already is.
  if pending() and forward then
    vim.cmd 'normal! v'
  end
  api.nvim_win_set_cursor(0, { row, col })
  return true
end

---After a jump: light up the character's other visible matches and let f / F / t / T
---(the same letter) and ; / , carry on. The first other key ends it and is run as usual.
local function char_loop()
  local win = api.nvim_get_current_win()
  local pat = '\\C\\V' .. vim.fn.escape(char.char, '\\')
  local ok, err = pcall(function()
    while true do
      local items = {}
      for _, m in ipairs(vim.fn.matchbufline(api.nvim_get_current_buf(), pat, vim.fn.line 'w0', vim.fn.line 'w$')) do
        items[#items + 1] = { win = win, row = m.lnum, col = m.byteidx, erow = m.lnum, ecol = m.byteidx + #m.text, hl = 'FlashMatch' }
      end
      render({ win }, items)
      vim.cmd.redraw()
      local got, key = pcall(vim.fn.getcharstr)
      if not got then
        return
      end
      if key == ';' or key == char.key then
        char_move(char.key, 1, true)
      elseif key == ',' or key == swapcase(char.key) then
        char_move(swapcase(char.key), 1, true)
      else
        -- At the front of the typeahead, so it still comes before the rest of a macro.
        -- Not as typed: getcharstr() already recorded it into any macro being recorded.
        api.nvim_feedkeys(key, 'mi', false)
        return
      end
    end
  end)
  clear { win }
  if not ok then
    error(err)
  end
end

function M.char(key)
  local op = pending()
  local count = vim.v.count1
  if not (op and repeating and char) then
    local ok, c = pcall(vim.fn.getcharstr)
    if not ok or c == ESC or c == '\3' or c:byte() == 0x80 then
      return op and cancel()
    end
    char = { char = c }
  end
  char.key = key
  if not char_move(key, count) then
    return op and cancel()
  end
  if not op then
    char_loop()
  end
end

---; (reverse = false) and , outside the loop.
function M.char_repeat(reverse)
  local op = pending()
  if not char then
    return op and cancel()
  end
  if not char_move(reverse and swapcase(char.key) or char.key, vim.v.count1, true) then
    return op and cancel()
  end
  if not op then
    char_loop()
  end
end

setup_highlight()

local group = api.nvim_create_augroup('core.flash', { clear = true })
api.nvim_create_autocmd('ColorScheme', { group = group, callback = setup_highlight })
api.nvim_create_autocmd('CmdlineChanged', { group = group, callback = search_update })
api.nvim_create_autocmd('CmdlineLeave', { group = group, callback = search_leave })

local map = vim.keymap.set
map({ 'n', 'x', 'o' }, 's', M.jump, { desc = 'Flash' })
map({ 'n', 'x', 'o' }, 'S', M.treesitter, { desc = 'Flash node' })
map('o', 'r', M.remote, { desc = 'Remote flash' })
map({ 'o', 'x' }, 'R', M.treesitter_search, { desc = 'Flash node search' })
map('c', '<C-s>', M.toggle, { desc = 'Toggle flash labels on the search' })
for _, key in ipairs { 'f', 'F', 't', 'T' } do
  map({ 'n', 'x', 'o' }, key, function()
    M.char(key)
  end, { desc = 'Flash ' .. key })
end
map({ 'n', 'x', 'o' }, ';', function()
  M.char_repeat(false)
end, { desc = 'Repeat f / t' })
map({ 'n', 'x', 'o' }, ',', function()
  M.char_repeat(true)
end, { desc = 'Repeat f / t backwards' })

return M
