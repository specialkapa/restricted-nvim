-- CSV / TSV viewer: a bordered, aligned table, a sticky header, and row filters.
--
--   | id | name   | amount |      <- drawn with virtual text and conceal; the file on
--   |  1 | bob    |  12.50 |         disk is never touched
--
-- What you search, yank and write is the real text, so `/`, n, N, * and :s work as usual,
-- and j/k stay in the same column. Each delimiter is concealed as a border (in insert
-- mode the cursor line shows the real delimiter, at the same width). Numeric columns are
-- right-aligned; NULL, \N and empty cells don't stop a column being numeric. When line 1
-- scrolls out of view it stays pinned at the top. Only lines near the window are
-- decorated, so a 100k-row file costs about the same as a small one once measured.
--
-- The window bar shows the column under the cursor, the active filters and the keys:
--   <Tab> <S-Tab>    next / previous column
--   <leader>cf       filter on the column under the cursor (dialog)
--   <leader>tc       toggle the table view (:CsvAlign, also works on any buffer)
--   <CR>  q          in a filter view: open this row in the file / go back to the file
--   :CsvHeader       toggle whether line 1 is a header
--
-- In the filter dialog, type a condition for that column:
--   UK          equal to UK              (empty: equal to the cell under the cursor)
--   != UK       > 4000      <= 10        (numeric when both sides are numbers)
--   ~ ^smi      !~ test                  (Vim regex)
--   > 100 && < 500         amount > 100  (&& joins; name another column to use it)
-- <Up>/<Down> recall earlier filters. :CsvFilter {expr} takes the same conditions with
-- explicit column names, or a Vim regex for the whole row; :CsvFilter! inverts.
--
-- A filter opens a read-only view of the matching rows; filter it again to narrow
-- further, and `:w out.csv` saves it.

local M = {}
local api = vim.api

local MAX_LINES = 200000 -- above this, alignment waits for :CsvAlign
local MAX_WIDTH = vim.g.csv_max_width or 50 -- a longer cell overflows instead of widening its column
local NULLS = { [''] = true, NULL = true, null = true, ['\\N'] = true, NaN = true, nan = true }
local QUOTE = 34 -- string.byte('"')

local ns = api.nvim_create_namespace('csv')
local S = {} -- buf -> state
local H = {} -- win -> sticky header float
local view_count = 0

local BAR = '\u{2502}' -- box drawing vertical line

local function setup_highlight()
  api.nvim_set_hl(0, 'CsvBorder', { link = 'Comment', default = true })
  api.nvim_set_hl(0, 'CsvHeader', { bold = true, underline = true, default = true })
  local border = api.nvim_get_hl(0, { name = 'CsvBorder', link = false })
  api.nvim_set_hl(0, 'CsvHeaderBorder', { fg = border.fg, underline = true, default = true })
end

---Split a line into fields. Returns start and end byte positions (1-based, inclusive;
---an empty field has e == s - 1) and the field count. Quotes are only honoured for CSV:
---"a,b" is one field and "" inside it is an escaped quote.
local function split(line, sep, quoted)
  local starts, ends = {}, {}
  local n, i, k = #line, 1, 0
  while true do
    k = k + 1
    starts[k] = i
    if quoted and line:byte(i) == QUOTE then
      local j = i + 1
      while j <= n do
        if line:byte(j) == QUOTE then
          if line:byte(j + 1) ~= QUOTE then
            break
          end
          j = j + 2
        else
          j = j + 1
        end
      end
      i = j + 1
    end
    local p = line:find(sep, i, true)
    if not p then
      ends[k] = n
      return starts, ends, k
    end
    ends[k] = p - 1
    i = p + 1
  end
end

---Display width of line:sub(s, e); `ascii` skips the slow path for plain lines.
local function width(line, s, e, ascii)
  if ascii then
    return e - s + 1
  end
  return api.nvim_strwidth(line:sub(s, e))
end

local function is_ascii(line)
  return not line:find('[\128-\255]')
end

---Cell text without surrounding blanks and quotes.
local function unquote(v)
  v = v:match('^%s*(.-)%s*$')
  if #v >= 2 and v:sub(1, 1) == '"' and v:sub(-1) == '"' then
    v = (v:sub(2, -2):gsub('""', '"'))
  end
  return v
end

local function cell(line, s, e)
  return unquote(line:sub(s, e))
end

---Delimiter: b:csv_delimiter if set, tab for tsv, else whichever of , ; | <Tab> is most
---common in the first line.
local function detect_sep(buf)
  local d = vim.b[buf].csv_delimiter
  if d == '\\t' then
    d = '\t'
  end
  if type(d) == 'string' and #d == 1 then
    return d
  end
  if vim.bo[buf].filetype == 'tsv' then
    return '\t'
  end
  local first = api.nvim_buf_get_lines(buf, 0, 1, false)[1] or ''
  local best, most = ',', 0
  for _, c in ipairs({ ',', ';', '|', '\t' }) do
    local _, count = first:gsub(vim.pesc(c), '')
    if count > most then
      best, most = c, count
    end
  end
  return best
end

---Measure every column: widest cell (capped) and whether it only holds numbers.
local function measure(buf, st)
  local widths, numeric, text = {}, {}, {}
  local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
  for i, line in ipairs(lines) do
    local starts, ends, n = split(line, st.sep, st.quoted)
    local ascii = is_ascii(line)
    local body = not (st.header and i == 1)
    for k = 1, n do
      local s, e = starts[k], ends[k]
      local w = math.min(width(line, s, e, ascii), MAX_WIDTH)
      if w > (widths[k] or 0) then
        widths[k] = w
      end
      if body and not text[k] and e >= s then
        local v = line:sub(s, e):match('^%s*(.-)%s*$')
        if not NULLS[v] then
          if tonumber(v) then
            numeric[k] = true
          else
            text[k] = true
          end
        end
      end
    end
  end
  for k in pairs(text) do
    numeric[k] = nil
  end
  st.widths, st.numeric = widths, numeric
end

---Decorate one line (0-based row) as a table row:  | cell | cell |
---Padding goes after a cell (before it for numbers), each delimiter is concealed as a
---border, and a row with fewer cells than the widest one gets empty cells at the end.
local function render_line(buf, st, row, line)
  if line == '' then
    return
  end
  local starts, ends, n = split(line, st.sep, st.quoted)
  local ascii = is_ascii(line)
  local header = st.header and row == 0
  local hl = header and 'CsvHeader' or nil
  local bhl = header and 'CsvHeaderBorder' or 'CsvBorder'
  local function put(col, chunks)
    api.nvim_buf_set_extmark(buf, ns, row, col, { virt_text = chunks, virt_text_pos = 'inline', right_gravity = false })
  end
  for k = 1, n do
    local s, e = starts[k], ends[k]
    local missing = math.max((st.widths[k] or 0) - width(line, s, e, ascii), 0)
    local right = st.numeric[k]
    local lead = { string.rep(' ', 1 + (right and missing or 0)), hl }
    if k == 1 then
      put(0, { { BAR, bhl }, lead })
    else
      put(s - 1, { lead })
    end
    local trail = { { string.rep(' ', 1 + (right and 0 or missing)), hl } }
    if k == n then
      trail[#trail + 1] = { BAR, bhl }
      for j = n + 1, #st.widths do
        trail[#trail + 1] = { string.rep(' ', st.widths[j] + 2), hl }
        trail[#trail + 1] = { BAR, bhl }
      end
    else
      api.nvim_buf_set_extmark(buf, ns, row, e, { end_col = e + 1, conceal = BAR, hl_group = bhl })
    end
    put(e, trail)
    if header and e >= s then
      api.nvim_buf_set_extmark(buf, ns, row, s - 1, { end_col = e, hl_group = 'CsvHeader' })
    end
  end
end

---Decorate the lines in and around the window that aren't done yet.
local function render_win(win)
  local buf = api.nvim_win_get_buf(win)
  local st = S[buf]
  if not (st and st.enabled) then
    return
  end
  local top = vim.fn.line('w0', win)
  local h = api.nvim_win_get_height(win)
  local from = math.max(1, top - h)
  local to = math.min(api.nvim_buf_line_count(buf), top + 2 * h)
  local lines = api.nvim_buf_get_lines(buf, from - 1, to, false)
  for i, line in ipairs(lines) do
    local row = from + i - 2
    if not st.rendered[row] then
      st.rendered[row] = true
      render_line(buf, st, row, line)
    end
  end
end

-- Sticky header ----------------------------------------------------------------------

local function close_header(win)
  local f = H[win]
  H[win] = nil
  if f and api.nvim_win_is_valid(f) then
    api.nvim_win_close(f, true)
  end
end

---Scratch buffer holding a copy of line 1, decorated exactly like the real one.
local function header_buf(buf, st)
  if not (st.hdr and api.nvim_buf_is_valid(st.hdr)) then
    st.hdr = api.nvim_create_buf(false, true)
    vim.bo[st.hdr].bufhidden = 'wipe'
    vim.b[st.hdr].csv_delimiter = vim.b[buf].csv_delimiter
    vim.bo[st.hdr].syntax = vim.bo[buf].syntax
  end
  local line = api.nvim_buf_get_lines(buf, 0, 1, false)[1] or ''
  api.nvim_buf_set_lines(st.hdr, 0, -1, false, { line })
  api.nvim_buf_clear_namespace(st.hdr, ns, 0, -1)
  render_line(st.hdr, st, 0, line)
  return st.hdr
end

---Show line 1 over the top of the window while it is scrolled out of view, scrolled
---sideways by the same amount as the window.
local function update_header(win)
  if not api.nvim_win_is_valid(win) then
    return close_header(win)
  end
  local buf = api.nvim_win_get_buf(win)
  local st = S[buf]
  local info = vim.fn.getwininfo(win)[1]
  if not (st and st.enabled and st.header and info and vim.fn.line('w0', win) > 1) or info.width <= info.textoff then
    return close_header(win)
  end
  local config = {
    relative = 'win',
    win = win,
    row = 0,
    col = info.textoff,
    width = info.width - info.textoff,
    height = 1,
    focusable = false,
    style = 'minimal',
    zindex = 40,
  }
  local f = H[win]
  local hb = header_buf(buf, st)
  if f and api.nvim_win_is_valid(f) then
    if api.nvim_win_get_buf(f) ~= hb then
      api.nvim_win_set_buf(f, hb)
    end
    api.nvim_win_set_config(f, config)
  else
    config.noautocmd = true -- only allowed when opening
    f = api.nvim_open_win(hb, false, config)
    H[win] = f
    vim.wo[f].wrap = false
    vim.wo[f].sidescrolloff = 0
    vim.wo[f].conceallevel = 2
    vim.wo[f].concealcursor = 'nvic'
    vim.wo[f].winhighlight = 'NormalFloat:Normal,Conceal:CsvBorder'
  end
  local leftcol = api.nvim_win_call(win, function()
    return vim.fn.winsaveview().leftcol
  end)
  api.nvim_win_call(f, function()
    vim.fn.winrestview({ topline = 1, lnum = 1, col = 0, leftcol = leftcol })
  end)
end

local function update_all()
  for win in pairs(H) do
    if not api.nvim_win_is_valid(win) or not S[api.nvim_win_get_buf(win)] then
      close_header(win)
    end
  end
  for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
    if S[api.nvim_win_get_buf(win)] and api.nvim_win_get_config(win).relative == '' then
      render_win(win)
      update_header(win)
    end
  end
end

-- Refresh ----------------------------------------------------------------------------

local function refresh(buf)
  local st = S[buf]
  api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  st.rendered = {}
  if st.enabled then
    measure(buf, st)
  end
  update_all()
end

---Re-measure shortly after the last edit, not on every keystroke.
local function refresh_later(buf)
  local st = S[buf]
  st.tick = (st.tick or 0) + 1
  local tick = st.tick
  vim.defer_fn(function()
    if S[buf] == st and st.tick == tick and api.nvim_buf_is_valid(buf) then
      refresh(buf)
    end
  end, 150)
end

-- Fields under the cursor --------------------------------------------------------------

---Index of the field under the cursor of `win` (default: current), plus the split line.
local function field_at_cursor(st, win)
  win = win or api.nvim_get_current_win()
  local pos = api.nvim_win_get_cursor(win)
  local line = api.nvim_buf_get_lines(api.nvim_win_get_buf(win), pos[1] - 1, pos[1], false)[1] or ''
  local col = pos[2] + 1
  local starts, ends, n = split(line, st.sep, st.quoted)
  for k = 1, n do
    if col <= ends[k] + 1 then
      return k, line, starts, ends, n
    end
  end
  return n, line, starts, ends, n
end

local function jump_field(delta)
  local st = S[api.nvim_get_current_buf()]
  local k, _, starts, _, n = field_at_cursor(st)
  local target = math.min(math.max(k + delta, 1), n)
  api.nvim_win_set_cursor(0, { api.nvim_win_get_cursor(0)[1], starts[target] - 1 })
end

---Header cells of a buffer, unquoted.
local function header_names(buf, st)
  local line = api.nvim_buf_get_lines(buf, 0, 1, false)[1] or ''
  local starts, ends, n = split(line, st.sep, st.quoted)
  local names = {}
  for k = 1, n do
    names[k] = cell(line, starts[k], ends[k])
  end
  return names
end

local function column_index(buf, st, name)
  name = unquote(name):lower()
  if st.header then
    for k, h in ipairs(header_names(buf, st)) do
      if h:lower() == name then
        return k
      end
    end
  end
  local k = tonumber(name)
  return k and k >= 1 and math.floor(k) == k and k or nil
end

-- Filtering ----------------------------------------------------------------------------

local OPS = { ['='] = true, ['=='] = true, ['!='] = true, ['<'] = true, ['<='] = true, ['>'] = true, ['>='] = true, ['~'] = true, ['!~'] = true }

local function compare(op, a, b)
  if op == '=' or op == '==' then
    return a == b
  elseif op == '!=' then
    return a ~= b
  elseif op == '<' then
    return a < b
  elseif op == '<=' then
    return a <= b
  elseif op == '>' then
    return a > b
  end
  return a >= b
end

---Turn an expression into a list of predicates fn(line, get) where get(k) is cell k.
local function compile(buf, st, expr)
  local preds = {}
  for part in vim.gsplit(expr, '&&', { plain = true }) do
    local col, op, val = part:match('^%s*(.-)%s*([=!<>~]+)%s*(.-)%s*$')
    local k = col and col ~= '' and OPS[op] and column_index(buf, st, col)
    if k then
      val = unquote(val)
      if op == '~' or op == '!~' then
        local re = vim.regex(val)
        local want = op == '~'
        preds[#preds + 1] = function(_, get)
          return (re:match_str(get(k)) ~= nil) == want
        end
      else
        local num = tonumber(val)
        preds[#preds + 1] = function(_, get)
          local v = get(k)
          local x = num and tonumber(v)
          if x then
            return compare(op, x, num)
          end
          -- A number compared with a non-number (NULL, '') only passes for !=.
          if num and (op ~= '=' and op ~= '==' and op ~= '!=') then
            return false
          end
          return compare(op, v, val)
        end
      end
    else
      local re = vim.regex(vim.trim(part))
      preds[#preds + 1] = function(line)
        return re:match_str(line) ~= nil
      end
    end
  end
  return preds
end

---The original buffer and line number behind line `lnum` of `buf`.
local function origin(buf, lnum)
  local st = S[buf]
  if st and st.rows then
    return st.origin, st.rows[lnum]
  end
  return buf, lnum
end

local function back_to_origin(target_lnum)
  local view = api.nvim_get_current_buf()
  local st = S[view]
  if not api.nvim_buf_is_valid(st.origin) then
    return vim.notify('csv: the original buffer is gone', vim.log.levels.WARN)
  end
  local lnum = target_lnum or st.return_lnum
  api.nvim_win_set_buf(0, st.origin)
  pcall(api.nvim_win_set_cursor, 0, { lnum, 0 })
  vim.cmd('normal! zz')
end

function M.filter(expr, invert)
  local buf = api.nvim_get_current_buf()
  local st = S[buf] or M.attach(buf, true)
  local ok, preds = pcall(compile, buf, st, expr)
  if not ok then
    return vim.notify('csv: ' .. tostring(preds), vim.log.levels.ERROR)
  end

  local col = field_at_cursor(st)
  local src = api.nvim_buf_get_lines(buf, 0, -1, false)
  local out, rows = {}, {}
  local first = 1
  if st.header and src[1] then
    out[1], rows[1], first = src[1], select(2, origin(buf, 1)), 2
  end
  local root = origin(buf, 1)
  for i = first, #src do
    local line = src[i]
    local starts, ends, n
    local function get(k)
      if not starts then
        starts, ends, n = split(line, st.sep, st.quoted)
      end
      return k <= n and cell(line, starts[k], ends[k]) or ''
    end
    local keep = true
    for _, p in ipairs(preds) do
      if not p(line, get) then
        keep = false
        break
      end
    end
    if keep ~= (invert or false) then
      out[#out + 1] = line
      local _, l = origin(buf, i)
      rows[#out] = l
    end
  end

  local matched = #out - (first - 1)
  local return_lnum = select(2, origin(buf, api.nvim_win_get_cursor(0)[1]))
  view_count = view_count + 1
  local view = api.nvim_create_buf(true, true)
  api.nvim_buf_set_name(view, string.format('%s [%s%s] #%d', vim.fn.fnamemodify(api.nvim_buf_get_name(root), ':t'), invert and 'NOT ' or '', expr, view_count))
  api.nvim_buf_set_lines(view, 0, -1, false, out)
  vim.bo[view].bufhidden = 'hide'
  vim.bo[view].modifiable = false
  vim.bo[view].modified = false

  vim.b[view].csv_delimiter = vim.b[buf].csv_delimiter or (st.sep == '\t' and '\\t' or st.sep)
  api.nvim_win_set_buf(0, view)
  -- Setting the filetype attaches through the FileType autocmd (csv/tsv); attach() covers
  -- anything else, e.g. a .txt you ran :CsvAlign on.
  vim.bo[view].filetype = vim.bo[buf].filetype ~= '' and vim.bo[buf].filetype or 'csv'
  local vs = M.attach(view, true)
  vs.origin, vs.rows, vs.return_lnum = root, rows, return_lnum
  vs.filters = vim.list_extend(vim.deepcopy(st.filters or {}), { (invert and 'NOT ' or '') .. expr })
  if vs.header ~= st.header or not vs.enabled then
    vs.header, vs.enabled = st.header, true
    refresh(view)
  end
  -- Land on the first row, in the column you filtered from.
  if out[first] then
    local starts, _, n = split(out[first], st.sep, st.quoted)
    api.nvim_win_set_cursor(0, { first, starts[math.min(col, n)] - 1 })
  end

  local map = function(lhs, fn, desc)
    vim.keymap.set('n', lhs, fn, { buffer = view, nowait = true, desc = 'CSV view: ' .. desc })
  end
  map('<CR>', function()
    back_to_origin(S[view].rows[api.nvim_win_get_cursor(0)[1]])
  end, 'jump to this row in the original file')
  map('q', function()
    back_to_origin()
    pcall(api.nvim_buf_delete, view, { force = true })
  end, 'back to the original file')

  vim.notify(string.format('csv: %d of %d rows', matched, #src - (first - 1)))
end

-- Filter dialog ------------------------------------------------------------------------

local history = {}

local function quote(v)
  return '"' .. v:gsub('"', '""') .. '"'
end

---A one-line input box under the cursor. on_submit gets the typed text ('' if empty).
local function input(title, placeholder, on_submit)
  local from = api.nvim_get_current_win()
  local b = api.nvim_create_buf(false, true)
  vim.bo[b].bufhidden = 'wipe'
  local footer = ' <CR> apply  <Esc> cancel  <Up>/<Down> history '
  local w = math.max(api.nvim_strwidth(placeholder) + 4, #footer + 2, #title + 4)
  local win = api.nvim_open_win(b, true, {
    relative = 'cursor',
    row = 1,
    col = 0,
    width = math.min(w, vim.o.columns - 4),
    height = 1,
    style = 'minimal',
    border = 'rounded',
    title = ' ' .. title .. ' ',
    footer = footer,
    footer_pos = 'right',
  })
  vim.wo[win].winhighlight = 'NormalFloat:Normal,FloatTitle:Title,FloatFooter:Comment'

  -- Placeholder text while the box is empty.
  local pns = api.nvim_create_namespace('csv-input')
  local function hint()
    api.nvim_buf_clear_namespace(b, pns, 0, -1)
    if api.nvim_buf_get_lines(b, 0, 1, false)[1] == '' then
      api.nvim_buf_set_extmark(b, pns, 0, 0, { virt_text = { { placeholder, 'Comment' } }, virt_text_pos = 'inline' })
    end
  end
  hint()
  api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI' }, { buffer = b, callback = hint })

  local closed = false
  local function close()
    if closed then
      return
    end
    closed = true
    if api.nvim_win_is_valid(win) then
      api.nvim_win_close(win, true)
    end
    if api.nvim_win_is_valid(from) then
      api.nvim_set_current_win(from)
    end
  end
  local function submit()
    local text = vim.trim(api.nvim_buf_get_lines(b, 0, 1, false)[1] or '')
    close()
    if text ~= '' and history[#history] ~= text then
      history[#history + 1] = text
    end
    vim.schedule(function()
      on_submit(text)
    end)
  end
  local pos = #history + 1
  local function recall(delta)
    pos = math.min(math.max(pos + delta, 1), #history + 1)
    local text = history[pos] or ''
    api.nvim_buf_set_lines(b, 0, -1, false, { text })
    api.nvim_win_set_cursor(win, { 1, #text })
  end

  local function map(modes, lhs, fn)
    vim.keymap.set(modes, lhs, fn, { buffer = b, nowait = true })
  end
  -- In insert mode, leave it in the box first; leaving it after switching back would move
  -- the cursor in the CSV window.
  local function from_insert(fn)
    return function()
      vim.schedule(fn)
      return '<Esc>'
    end
  end
  vim.keymap.set('i', '<CR>', from_insert(submit), { buffer = b, expr = true })
  vim.keymap.set('i', '<Esc>', from_insert(close), { buffer = b, expr = true })
  vim.keymap.set('i', '<C-c>', from_insert(close), { buffer = b, expr = true })
  map('n', '<CR>', submit)
  map('n', '<Esc>', close)
  map('n', 'q', close)
  map('i', '<Up>', function()
    recall(-1)
  end)
  map('i', '<Down>', function()
    recall(1)
  end)
  api.nvim_create_autocmd('WinLeave', { buffer = b, once = true, callback = close })
  vim.cmd.startinsert()
end

---Turn what was typed in the dialog into a :CsvFilter expression for column `name`.
local function dialog_expr(name, value, text)
  if text == '' then
    return name .. ' = ' .. quote(value)
  end
  local parts = {}
  for part in vim.gsplit(text, '&&', { plain = true }) do
    part = vim.trim(part)
    if part:match('^[=!<>~]') then
      parts[#parts + 1] = name .. ' ' .. part -- an operator: this column
    elseif part:find('[=!<>~]') then
      parts[#parts + 1] = part -- names its own column
    else
      parts[#parts + 1] = name .. ' = ' .. quote(part) -- a bare value
    end
  end
  return table.concat(parts, ' && ')
end

---Open the filter dialog for the column under the cursor.
function M.filter_dialog()
  local buf = api.nvim_get_current_buf()
  local st = S[buf] or M.attach(buf, true)
  local k, line, starts, ends = field_at_cursor(st)
  local label = st.header and header_names(buf, st)[k] or ''
  local name = label
  -- Refer to the column by number when the name is missing, ambiguous or holds an operator.
  if name == '' or name:find('[=!<>~&]') or column_index(buf, st, name) ~= k then
    name = tostring(k)
  end
  -- On the header row there is no cell value to default to.
  local on_header = st.header and api.nvim_win_get_cursor(0)[1] == 1
  local value = not on_header and cell(line, starts[k], ends[k]) or nil
  local title = string.format('Filter %s(column %d)', label ~= '' and label .. ' ' or '', k)
  local placeholder = (value and '= ' .. value .. '   or  ' or '') .. '!= x  > 10  ~ regex  && ...'
  input(title, placeholder, function(text)
    if text == '' and not value then
      return
    end
    M.filter(dialog_expr(name, value, text))
  end)
end

-- Window bar -------------------------------------------------------------------------

local function key(lhs, what)
  return '%#Special#' .. lhs .. '%#Comment# ' .. what .. '  '
end

---Window bar for a CSV window: column under the cursor, filters, and the keys.
function M.winbar()
  local win = vim.g.statusline_winid or api.nvim_get_current_win()
  local buf = api.nvim_win_get_buf(win)
  local st = S[buf]
  if not st then
    return ''
  end
  local esc = function(text)
    return (text:gsub('%%', '%%%%'))
  end
  local k = field_at_cursor(st, win)
  local name = st.header and header_names(buf, st)[k] or ''
  local rows = api.nvim_buf_line_count(buf) - (st.header and 1 or 0)
  local out = { ' %#Title#', esc(name ~= '' and name or ('column ' .. k)) }
  out[#out + 1] = string.format('%%#Comment# %d/%d  %d rows', k, math.max(#st.widths, k), rows)
  if st.filters then
    out[#out + 1] = '  %#Comment#filter %#Normal#' .. table.concat(vim.tbl_map(esc, st.filters), ' %#Comment#\u{203A}%#Normal# ')
  end
  out[#out + 1] = '%<%='
  local leader = vim.g.mapleader == ' ' and '\u{2423}' or (vim.g.mapleader or '\\')
  out[#out + 1] = key('<Tab>', 'column')
  out[#out + 1] = key(leader .. 'cf', 'filter')
  if st.rows then
    out[#out + 1] = key('<CR>', 'open row')
    out[#out + 1] = key('q', 'back')
  end
  out[#out + 1] = key(leader .. 'tc', 'table')
  return table.concat(out)
end

---Window options for a CSV window (local to this buffer in it).
local function setup_win(win)
  api.nvim_win_call(win, function()
    vim.opt_local.wrap = false
    vim.opt_local.conceallevel = 2
    vim.opt_local.concealcursor = 'nc'
    vim.opt_local.winhighlight = 'Conceal:CsvBorder'
    vim.opt_local.winbar = "%{%v:lua.require'core.csv'.winbar()%}"
  end)
end

-- Attach / toggle ----------------------------------------------------------------------

function M.attach(buf, force)
  if S[buf] then
    return S[buf]
  end
  local sep = detect_sep(buf)
  local big = api.nvim_buf_line_count(buf) > MAX_LINES
  local st = { sep = sep, quoted = sep ~= '\t', header = true, enabled = force or not big, rendered = {}, widths = {}, numeric = {} }
  S[buf] = st
  if vim.b[buf].csv_delimiter == nil then
    vim.b[buf].csv_delimiter = sep == '\t' and '\\t' or sep -- for the built-in syntax
  end
  if big and not force then
    vim.notify('csv: large file, not aligning (:CsvAlign to align anyway)', vim.log.levels.INFO)
  end

  local group = api.nvim_create_augroup('user-csv-' .. buf, { clear = true })
  api.nvim_create_autocmd({ 'TextChanged', 'InsertLeave' }, {
    group = group,
    buffer = buf,
    callback = function()
      refresh_later(buf)
    end,
  })
  api.nvim_create_autocmd('BufWinEnter', {
    group = group,
    buffer = buf,
    callback = function()
      setup_win(api.nvim_get_current_win())
    end,
  })
  -- The window bar shows the column under the cursor; redraw it when that changes.
  api.nvim_create_autocmd('CursorMoved', {
    group = group,
    buffer = buf,
    callback = function()
      local k = field_at_cursor(st)
      if vim.w.csv_col ~= k then
        vim.w.csv_col = k
        vim.cmd.redrawstatus()
      end
    end,
  })
  api.nvim_create_autocmd('BufWipeout', {
    group = group,
    buffer = buf,
    callback = function()
      if st.hdr and api.nvim_buf_is_valid(st.hdr) then
        vim.schedule(function()
          pcall(api.nvim_buf_delete, st.hdr, { force = true })
        end)
      end
      S[buf] = nil
      api.nvim_del_augroup_by_id(group)
    end,
  })

  local map = function(lhs, fn, desc)
    vim.keymap.set('n', lhs, fn, { buffer = buf, desc = 'CSV: ' .. desc })
  end
  map('<Tab>', function()
    jump_field(1)
  end, 'next field')
  map('<S-Tab>', function()
    jump_field(-1)
  end, 'previous field')
  map('<leader>cf', M.filter_dialog, '[F]ilter on this column')

  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    setup_win(win)
  end
  -- Measuring needs the buffer loaded; when attached from FileType it is.
  refresh(buf)
  return st
end

function M.toggle()
  local buf = api.nvim_get_current_buf()
  local st = S[buf]
  if not st then
    M.attach(buf, true)
    return
  end
  st.enabled = not st.enabled
  refresh(buf)
  vim.notify('CSV alignment ' .. (st.enabled and 'on' or 'off'))
end

function M.toggle_header()
  local buf = api.nvim_get_current_buf()
  local st = S[buf] or M.attach(buf, true)
  st.header = not st.header
  refresh(buf)
  vim.notify('CSV header ' .. (st.header and 'on' or 'off'))
end

-- Setup ------------------------------------------------------------------------------

setup_highlight()

local group = api.nvim_create_augroup('user-csv', { clear = true })
api.nvim_create_autocmd('ColorScheme', { group = group, callback = setup_highlight })
api.nvim_create_autocmd('FileType', {
  group = group,
  pattern = { 'csv', 'tsv' },
  callback = function(args)
    M.attach(args.buf)
  end,
})
api.nvim_create_autocmd({ 'WinScrolled', 'WinResized', 'BufWinEnter', 'WinEnter' }, {
  group = group,
  callback = function()
    if next(S) then
      update_all()
    end
  end,
})
api.nvim_create_autocmd('WinClosed', {
  group = group,
  callback = function(args)
    local win = tonumber(args.match)
    if win and H[win] then
      vim.schedule(function()
        close_header(win)
      end)
    end
  end,
})

api.nvim_create_user_command('CsvAlign', M.toggle, { desc = 'Toggle CSV column alignment' })
api.nvim_create_user_command('CsvHeader', M.toggle_header, { desc = 'Toggle treating line 1 as a header' })
api.nvim_create_user_command('CsvFilter', function(o)
  M.filter(o.args, o.bang)
end, {
  nargs = '+',
  bang = true,
  desc = 'Show rows matching {expr} in a new view',
  complete = function(lead)
    local buf = api.nvim_get_current_buf()
    local st = S[buf]
    if not st then
      return {}
    end
    return vim.tbl_filter(function(name)
      return name:lower():find(lead:lower(), 1, true) == 1
    end, header_names(buf, st))
  end,
})

vim.keymap.set('n', '<leader>tc', M.toggle, { desc = '[T]oggle [C]SV column alignment' })

return M
