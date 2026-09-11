-- Fuzzy pickers with no plugins and no external binaries.
--
-- Nothing shells out: the file list comes from vim.uv.fs_scandir, filtering from the
-- builtin matchfuzzy(), grep from reading files in Lua. No ripgrep, no fd.
--
--   <leader>sf  find files
--   <leader>sg  live grep -- type in the prompt, results update as you go
--   <leader>sw  grep the word under the cursor / visual selection
--   <leader>sb  switch buffer
--   <leader>/   fuzzy find lines in the current buffer

local uv = vim.uv or vim.loop

local M = {}

local SKIP_DIRS = {
	[".git"] = true,
	[".venv"] = true,
	venv = true,
	["__pycache__"] = true,
	node_modules = true,
	[".mypy_cache"] = true,
	[".ruff_cache"] = true,
	[".pytest_cache"] = true,
	[".tox"] = true,
	dist = true,
	build = true,
	["site-packages"] = true,
}

local BINARY = {
	png = true,
	jpg = true,
	jpeg = true,
	gif = true,
	ico = true,
	pdf = true,
	zip = true,
	gz = true,
	whl = true,
	exe = true,
	dll = true,
	pyc = true,
	so = true,
	dylib = true,
	db = true,
	sqlite = true,
	parquet = true,
}

-- Float colours.
--
-- `style = 'minimal'` points 'winhighlight' at NormalFloat, and FloatBorder falls back to
-- a black background whenever the colorscheme does not define it -- which is the dark
-- frame you get with a hand-rolled theme. Rather than depend on those groups existing,
-- derive our own from Normal so the picker always sits on the editor background.
local function setup_highlights()
	local function get(name)
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

	local normal, comment = get("Normal"), get("Comment")
	vim.api.nvim_set_hl(0, "PickerNormal", { fg = normal.fg, bg = normal.bg })
	vim.api.nvim_set_hl(0, "PickerBorder", { fg = comment.fg or normal.fg, bg = normal.bg })
	vim.api.nvim_set_hl(0, "PickerTitle", { fg = normal.fg, bg = normal.bg, bold = true })
end

setup_highlights()
vim.api.nvim_create_autocmd("ColorScheme", {
	group = vim.api.nvim_create_augroup("picker-highlights", { clear = true }),
	callback = setup_highlights,
})

local WINHL = table.concat({
	"Normal:PickerNormal",
	"FloatBorder:PickerBorder",
	"FloatTitle:PickerTitle",
	"CursorLine:Visual",
	"EndOfBuffer:PickerNormal",
}, ",")

local MAX_FILES = 20000
local MAX_RESULTS = 2000
local MAX_RENDER = 300 -- lines drawn; filtering still sees everything
local PREVIEW_LINES = 500 -- how much of a file to read for the preview
local MAX_CORPUS_BYTES = 60e6 -- ceiling on the in-memory grep index
local DEBOUNCE_MS = 60 -- delay before a live query re-runs

-- What <CR> does with the selection. 'tabedit' opens each pick in its own tab; set to
-- 'edit' to open in the current window instead. <C-t>/<C-v>/<C-x> always override it.
local DEFAULT_ACTION = "tabedit"

-- Border style for all three float windows. Any nvim_open_win 'border' value:
-- 'none', 'single', 'double', 'rounded', 'solid', 'shadow', or an 8-element char list.
local BORDER = "single"

-- ripgrep, when the machine has it. Two things change: `rg --files` replaces the Lua
-- directory walk (and honours .gitignore), and grep becomes a real async live search
-- with regex support instead of a substring scan over an in-memory index. Everything
-- still works without it -- the pure-Lua paths below are the fallback.
local RG = vim.fn.executable("rg") == 1
local HAS_SYSTEM = vim.system ~= nil
local USE_RG = RG and HAS_SYSTEM

local function root()
	local found = vim.fs.find({ ".git", "pyproject.toml", "setup.py" }, { upward = true, path = vim.fn.getcwd() })[1]
	return found and vim.fs.dirname(found) or vim.fn.getcwd()
end

---Every file under `dir`, relative to it. Prunes ignored directories DURING the walk
---rather than filtering afterwards -- that is what keeps it fast next to a .venv.
local function list_files(dir)
	if RG then
		-- --files lists without searching; .gitignore is respected for free, which is
		-- better pruning than SKIP_DIRS can manage.
		local out = vim.fn.systemlist({ "rg", "--files", "--hidden", "--glob", "!.git/", "--path-separator", "/", dir })
		if vim.v.shell_error == 0 then
			local prefix = vim.fs.normalize(dir) .. "/"
			for i, path in ipairs(out) do
				local norm = vim.fs.normalize(path)
				out[i] = norm:sub(1, #prefix) == prefix and norm:sub(#prefix + 1) or norm
			end
			return out
		end
		-- rg failed (not a directory, permissions); fall through to the Lua walk.
	end

	local out = {}
	local function walk(path)
		if #out >= MAX_FILES then
			return
		end
		local fd = uv.fs_scandir(path)
		if not fd then
			return
		end
		while true do
			local name, kind = uv.fs_scandir_next(fd)
			if not name then
				break
			end
			local full = path .. "/" .. name
			if kind == "directory" then
				if not SKIP_DIRS[name] and name:sub(1, 1) ~= "." then
					walk(full)
				end
			elseif kind == "file" or kind == "link" then
				if #out >= MAX_FILES then
					return
				end
				out[#out + 1] = full:sub(#dir + 2)
			end
		end
	end
	walk(vim.fs.normalize(dir))
	return out
end

---Preview payload for a file on disk, or nil if unreadable.
local function file_preview(path, lnum)
	local ext = path:match("%.([%w]+)$")
	if ext and BINARY[ext:lower()] then
		return { lines = { "-- binary file --" } }
	end
	local ok, lines = pcall(vim.fn.readfile, path, "", PREVIEW_LINES)
	if not ok then
		return nil
	end
	return { lines = lines, ft = vim.filetype.match({ filename = path }), lnum = lnum }
end

-- ---------------------------------------------------------------------------
-- Grep corpus.
--
-- Live grep means re-scanning on every keystroke, and re-reading the tree from disk each
-- time is far too slow -- that is the job ripgrep does for telescope. Instead read every
-- text file ONCE into memory, keeping a lowercased copy for matching, and scan that.
-- ---------------------------------------------------------------------------

local corpus_cache = {}

local function build_corpus(dir)
	local files, bytes = {}, 0
	for _, rel in ipairs(list_files(dir)) do
		local ext = rel:match("%.([%w]+)$")
		if not (ext and BINARY[ext:lower()]) and bytes < MAX_CORPUS_BYTES then
			local ok, lines = pcall(vim.fn.readfile, vim.fs.normalize(dir .. "/" .. rel))
			if ok then
				local lower = {}
				for i, line in ipairs(lines) do
					lower[i] = line:lower()
					bytes = bytes + #line
				end
				files[#files + 1] = { file = rel, lines = lines, lower = lower }
			end
		end
	end
	if bytes >= MAX_CORPUS_BYTES then
		vim.notify("grep index truncated at " .. math.floor(MAX_CORPUS_BYTES / 1e6) .. "MB", vim.log.levels.WARN)
	end
	return files
end

local function corpus(dir)
	if not corpus_cache[dir] then
		corpus_cache[dir] = build_corpus(dir)
	end
	return corpus_cache[dir]
end

---Case-insensitive substring scan over the cached corpus.
local function search(dir, needle)
	local out = {}
	needle = needle:lower()
	for _, f in ipairs(corpus(dir)) do
		local lower, lines = f.lower, f.lines
		for lnum = 1, #lower do
			if lower[lnum]:find(needle, 1, true) then
				out[#out + 1] = { file = f.file, lnum = lnum, text = vim.trim(lines[lnum]) }
				if #out >= MAX_RESULTS then
					return out
				end
			end
		end
	end
	return out
end

-- Keep the cache honest for your own edits: re-read just the saved file rather than
-- invalidating the whole index.
vim.api.nvim_create_autocmd("BufWritePost", {
	group = vim.api.nvim_create_augroup("picker-corpus", { clear = true }),
	callback = function(args)
		local path = vim.fs.normalize(vim.api.nvim_buf_get_name(args.buf))
		for dir, files in pairs(corpus_cache) do
			local prefix = vim.fs.normalize(dir) .. "/"
			if path:sub(1, #prefix) == prefix then
				local rel = path:sub(#prefix + 1)
				for _, f in ipairs(files) do
					if f.file == rel then
						local ok, lines = pcall(vim.fn.readfile, path)
						if ok then
							local lower = {}
							for i, line in ipairs(lines) do
								lower[i] = line:lower()
							end
							f.lines, f.lower = lines, lower
						end
						return
					end
				end
			end
		end
	end,
})

---Async live grep through ripgrep. Returns the job handle so a superseded query can be
---killed rather than left running.
---@param dir string
---@param query string
---@param cb fun(items: table[])
local function rg_search(dir, query, cb)
	return vim.system(
		{ "rg", "--vimgrep", "--smart-case", "--color", "never", "--max-columns", "500", "--", query },
		{ cwd = dir, text = true },
		function(res)
			local items = {}
			-- rg exits 1 for "no matches", which is not an error.
			for line in (res.stdout or ""):gmatch("[^\n]+") do
				local file, lnum, text = line:match("^(.-):(%d+):%d+:(.*)$")
				if file then
					items[#items + 1] = { file = file, lnum = tonumber(lnum), text = vim.trim(text) }
					if #items >= MAX_RESULTS then
						break
					end
				end
			end
			vim.schedule(function()
				cb(items)
			end)
		end
	)
end

vim.api.nvim_create_user_command("PickerReindex", function()
	corpus_cache = {}
	vim.notify("grep index cleared", vim.log.levels.INFO)
end, { desc = "Drop the cached grep index" })

-- ---------------------------------------------------------------------------
-- The picker: prompt on top, results left, optional preview right.
-- ---------------------------------------------------------------------------

---@param opts table items|dynamic, prompt, on_choice, format(item), preview(item), initial
local function pick(opts)
	local format = opts.format or tostring
	local has_preview = opts.preview ~= nil
	-- Dynamic sources recompute their items from the query (live grep). Static ones are
	-- fuzzy-filtered with matchfuzzy against a fixed list.
	local dynamic = opts.dynamic
	-- An async source takes (query, callback) instead of returning items. Results that
	-- arrive after a newer query was typed are discarded via the generation counter.
	local dynamic_async = opts.dynamic_async

	if not dynamic and not dynamic_async and #(opts.items or {}) == 0 then
		vim.notify("nothing to pick from", vim.log.levels.INFO)
		return
	end

	local display, by_text = {}, {}

	local function set_items(items)
		display, by_text = {}, {}
		for _, item in ipairs(items) do
			local text = format(item)
			display[#display + 1] = text
			by_text[text] = by_text[text] or item
		end
	end

	set_items(opts.items or {})
	local filtered, sel = display, 1

	-- Declared up here because close() below refers to them; a local defined later would
	-- silently be a different (global) name inside that closure.
	local generation = 0
	local inflight

	local total_w = math.min(180, math.floor(vim.o.columns * 0.85))
	local height = math.min(24, math.floor(vim.o.lines * 0.6))
	local list_w = has_preview and math.floor(total_w * 0.45) or total_w
	local prev_w = total_w - list_w - 2 -- 2 = the two adjoining borders, no gap between
	local col = math.floor((vim.o.columns - total_w) / 2)
	local row = math.max(1, math.floor((vim.o.lines - height) / 2) - 2)

	local list_buf = vim.api.nvim_create_buf(false, true)
	local prompt_buf = vim.api.nvim_create_buf(false, true)
	local prev_buf = has_preview and vim.api.nvim_create_buf(false, true) or nil

	local list_win = vim.api.nvim_open_win(list_buf, false, {
		relative = "editor",
		width = list_w,
		height = height,
		col = col,
		row = row + 3,
		style = "minimal",
		border = BORDER,
	})
	local prev_win = has_preview
			and vim.api.nvim_open_win(prev_buf, false, {
				relative = "editor",
				width = prev_w,
				height = height,
				col = col + list_w + 2,
				row = row + 3,
				style = "minimal",
				border = BORDER,
			})
		or nil
	local prompt_win = vim.api.nvim_open_win(prompt_buf, true, {
		relative = "editor",
		width = total_w,
		height = 1,
		col = col,
		row = row,
		style = "minimal",
		border = BORDER,
		title = " " .. (opts.prompt or "Pick") .. " ",
		title_pos = "center",
	})

	vim.wo[list_win].cursorline = true
	vim.wo[list_win].wrap = false
	-- Set after nvim_open_win: 'minimal' assigns winhighlight itself, so this overrides.
	vim.wo[list_win].winhighlight = WINHL
	vim.wo[prompt_win].winhighlight = WINHL
	if prev_win then
		vim.wo[prev_win].winhighlight = WINHL
		vim.wo[prev_win].wrap = false
		vim.wo[prev_win].cursorline = true
	end

	local closed = false
	local function close()
		if closed then
			return
		end
		closed = true
		if inflight then
			pcall(function()
				inflight:kill("sigterm")
			end)
			inflight = nil
		end
		-- Without this you land in the picked buffer still in insert mode.
		vim.cmd("stopinsert")
		pcall(vim.api.nvim_win_close, prompt_win, true)
		pcall(vim.api.nvim_win_close, list_win, true)
		if prev_win then
			pcall(vim.api.nvim_win_close, prev_win, true)
		end
		pcall(vim.api.nvim_buf_delete, prompt_buf, { force = true })
		pcall(vim.api.nvim_buf_delete, list_buf, { force = true })
		if prev_buf then
			pcall(vim.api.nvim_buf_delete, prev_buf, { force = true })
		end
	end

	-- Re-rendering the preview on every keystroke would re-read the same file, so skip
	-- when the highlighted entry has not actually changed.
	local last_preview
	local function render_preview()
		if not has_preview or closed then
			return
		end
		local text = filtered[sel]
		if text == last_preview then
			return
		end
		last_preview = text
		local item = text and by_text[text]
		local payload = item and opts.preview(item) or nil
		vim.bo[prev_buf].modifiable = true
		vim.api.nvim_buf_set_lines(prev_buf, 0, -1, false, payload and payload.lines or { "" })
		vim.bo[prev_buf].modifiable = false
		-- Built-in syntax (no treesitter here) keyed off the detected filetype.
		vim.bo[prev_buf].filetype = (payload and payload.ft) or ""
		local target = payload and payload.lnum or 1
		target = math.max(1, math.min(target, vim.api.nvim_buf_line_count(prev_buf)))
		pcall(vim.api.nvim_win_set_cursor, prev_win, { target, 0 })
		pcall(vim.api.nvim_win_call, prev_win, function()
			vim.cmd("normal! zz")
		end)
	end

	local function render()
		local shown = {}
		for i = 1, math.min(#filtered, MAX_RENDER) do
			shown[i] = filtered[i]
		end
		if #shown == 0 then
			local live = dynamic or dynamic_async
			shown = { live and #display == 0 and "  (type to search)" or "  (no matches)" }
		end
		vim.bo[list_buf].modifiable = true
		vim.api.nvim_buf_set_lines(list_buf, 0, -1, false, shown)
		vim.bo[list_buf].modifiable = false
		sel = math.max(1, math.min(sel, #shown))
		pcall(vim.api.nvim_win_set_cursor, list_win, { sel, 0 })
		pcall(vim.api.nvim_win_set_config, prompt_win, {
			title = (" %s  %d/%d "):format(opts.prompt or "Pick", #filtered, #display),
			title_pos = "center",
		})
		render_preview()
	end

	local function update()
		local query = vim.trim(vim.api.nvim_buf_get_lines(prompt_buf, 0, 1, false)[1] or "")

		if dynamic_async then
			-- Kill the previous search: on a fast typist every keystroke would otherwise
			-- leave an rg process running to completion for a query already discarded.
			if inflight then
				pcall(function()
					inflight:kill("sigterm")
				end)
				inflight = nil
			end
			generation = generation + 1
			local gen = generation
			if query == "" then
				set_items({})
				filtered, sel = display, 1
				render()
				return
			end
			inflight = dynamic_async(query, function(items)
				if closed or gen ~= generation then
					return -- a newer query already went out
				end
				inflight = nil
				set_items(items)
				filtered, sel = display, 1
				render()
			end)
			return
		end

		if dynamic then
			-- The query IS the search; no fuzzy pass on top of it.
			set_items(query == "" and {} or dynamic(query))
			filtered = display
		else
			-- matchfuzzy errors on an empty needle, so short-circuit it.
			filtered = query == "" and display or vim.fn.matchfuzzy(display, query)
		end
		sel = 1
		render()
	end

	-- A live scan per keystroke would fire mid-word; coalesce bursts of typing.
	local timer
	local function queue_update()
		if not dynamic and not dynamic_async then
			return update()
		end
		if timer then
			timer:stop()
		end
		timer = vim.defer_fn(function()
			if not closed then
				update()
			end
		end, DEBOUNCE_MS)
	end

	local function move(delta)
		local n = math.min(#filtered, MAX_RENDER)
		if n == 0 then
			return
		end
		sel = sel + delta
		if sel < 1 then
			sel = n
		elseif sel > n then
			sel = 1
		end
		pcall(vim.api.nvim_win_set_cursor, list_win, { sel, 0 })
		render_preview()
	end

	---Scroll the preview without moving the selection.
	local function scroll_preview(delta)
		if not prev_win then
			return
		end
		vim.api.nvim_win_call(prev_win, function()
			local line = vim.fn.line(".") + delta
			line = math.max(1, math.min(line, vim.api.nvim_buf_line_count(prev_buf)))
			vim.api.nvim_win_set_cursor(prev_win, { line, 0 })
			vim.cmd("normal! zz")
		end)
	end

	---@param action string an Ex command: 'edit', 'tabedit', 'vsplit', 'split'
	local function accept(action)
		local text = filtered[sel]
		close()
		if text and by_text[text] then
			vim.schedule(function()
				opts.on_choice(by_text[text], action or "edit")
			end)
		end
	end

	---Copy the highlighted entry's file path. Sources opt in by supplying opts.path;
	---those without one (buffer lines) simply do nothing. The picker stays open, so you
	---can look at the preview and copy without losing your place.
	---Flash a message in the prompt border for `ms`, then restore the normal title.
	---Confirmation has to live INSIDE the picker: a vim.notify lands on the command line,
	---which the picker's own redraw wipes immediately -- and shows nothing at all under
	---cmdheight=0.
	local function flash_title(message, ms)
		if closed then
			return
		end
		local budget = total_w - 4
		if #message > budget then
			message = "..." .. message:sub(#message - budget + 4)
		end
		pcall(vim.api.nvim_win_set_config, prompt_win, { title = " " .. message .. " ", title_pos = "center" })
		vim.defer_fn(function()
			if not closed then
				render() -- puts the "Files 12/840" counter back
			end
		end, ms or 1500)
	end

	local function yank_path()
		if not opts.path then
			flash_title("no path for this source")
			return
		end
		local text = filtered[sel]
		local item = text and by_text[text]
		local path = item and opts.path(item)
		if not path or path == "" then
			return
		end
		vim.fn.setreg('"', path)
		-- The + register needs a clipboard provider; core/clipboard.lua wires one up where
		-- the platform allows. Best-effort, because " always works regardless.
		local clipboard = vim.fn.has("clipboard") == 1 and pcall(vim.fn.setreg, "+", path)
		flash_title((clipboard and "copied  " or 'yanked to " only  ') .. path)
		-- Recorded as well, so :messages still has the full path after the flash clears.
		vim.notify("yanked: " .. path, vim.log.levels.INFO)
	end

	local map = function(lhs, fn)
		vim.keymap.set({ "i", "n" }, lhs, fn, { buffer = prompt_buf, nowait = true })
	end
	map("<CR>", function()
		accept(DEFAULT_ACTION)
	end)
	-- Telescope's open-in conventions, plus <C-e> to force the current window.
	map("<C-e>", function()
		accept("edit")
	end)
	map("<C-t>", function()
		accept("tabedit")
	end)
	map("<C-v>", function()
		accept("vsplit")
	end)
	map("<C-x>", function()
		accept("split")
	end)
	map("<Esc>", close)
	map("<C-c>", close)
	map("<C-n>", function()
		move(1)
	end)
	map("<C-p>", function()
		move(-1)
	end)
	map("<Down>", function()
		move(1)
	end)
	map("<Up>", function()
		move(-1)
	end)
	map("<C-y>", yank_path)
	map("<C-d>", function()
		scroll_preview(10)
	end)
	map("<C-u>", function()
		scroll_preview(-10)
	end)

	vim.api.nvim_create_autocmd({ "TextChangedI", "TextChanged" }, { buffer = prompt_buf, callback = queue_update })
	vim.api.nvim_create_autocmd("BufLeave", { buffer = prompt_buf, once = true, callback = close })

	if opts.initial and opts.initial ~= "" then
		vim.api.nvim_buf_set_lines(prompt_buf, 0, 1, false, { opts.initial })
		update()
	else
		render()
	end
	vim.cmd("startinsert!")
end

-- ---------------------------------------------------------------------------
-- Sources
-- ---------------------------------------------------------------------------

function M.files()
	local dir = root()
	pick({
		prompt = "Files",
		items = list_files(dir),
		preview = function(rel)
			return file_preview(vim.fs.normalize(dir .. "/" .. rel), 1)
		end,
		path = function(rel)
			return vim.fs.normalize(dir .. "/" .. rel)
		end,
		on_choice = function(rel, action)
			vim.cmd[action](vim.fn.fnameescape(vim.fs.normalize(dir .. "/" .. rel)))
		end,
	})
end

function M.buffers()
	local items = {}
	for _, b in ipairs(vim.api.nvim_list_bufs()) do
		local name = vim.api.nvim_buf_get_name(b)
		if vim.api.nvim_buf_is_loaded(b) and vim.bo[b].buflisted and name ~= "" then
			items[#items + 1] = { buf = b, name = vim.fn.fnamemodify(name, ":."), path = name }
		end
	end
	pick({
		prompt = "Buffers",
		items = items,
		format = function(i)
			return i.name
		end,
		preview = function(i)
			return file_preview(i.path, 1)
		end,
		path = function(i)
			return i.path
		end,
		-- Via the path rather than nvim_set_current_buf, so tabedit/vsplit/split all work.
		on_choice = function(i, action)
			vim.cmd[action](vim.fn.fnameescape(i.path))
		end,
	})
end

---Live grep: the prompt IS the pattern, re-scanned on every keystroke against the
---in-memory corpus. Plain substring, case-insensitive.
local function live_grep(initial)
	local dir = root()

	-- With ripgrep: a real async regex search per keystroke, nothing held in memory.
	-- Without it: the in-memory corpus, which must be read once up front.
	local source
	if USE_RG then
		source = {
			dynamic_async = function(query, cb)
				return rg_search(dir, query, cb)
			end,
		}
	else
		if not corpus_cache[dir] then
			vim.notify("indexing project for grep...", vim.log.levels.INFO)
			corpus(dir) -- pay the read cost once, before the picker opens
		end
		source = {
			dynamic = function(query)
				return search(dir, query)
			end,
		}
	end

	pick({
		prompt = USE_RG and "Grep (rg)" or "Grep",
		initial = initial,
		dynamic = source.dynamic,
		dynamic_async = source.dynamic_async,
		format = function(r)
			return ("%s:%d: %s"):format(r.file, r.lnum, r.text)
		end,
		preview = function(r)
			return file_preview(vim.fs.normalize(dir .. "/" .. r.file), r.lnum)
		end,
		path = function(r)
			return vim.fs.normalize(dir .. "/" .. r.file)
		end,
		on_choice = function(r, action)
			vim.cmd[action](vim.fn.fnameescape(vim.fs.normalize(dir .. "/" .. r.file)))
			pcall(vim.api.nvim_win_set_cursor, 0, { r.lnum, 0 })
			vim.cmd("normal! zz")
		end,
	})
end

function M.grep()
	live_grep(nil)
end

---The visually selected text, via a round trip through the unnamed register. Simpler and
---more portable than reading the '< '> marks, which need clamping for linewise
---selections where the end column is v:maxcol.
local function visual_selection()
	local save, save_type = vim.fn.getreg('"'), vim.fn.getregtype('"')
	vim.cmd("noautocmd normal! y")
	local text = vim.fn.getreg('"')
	vim.fn.setreg('"', save, save_type)
	-- A multi-line selection is not a useful needle; take the first line.
	return (text:gsub("\n.*", ""))
end

function M.grep_word()
	local mode = vim.fn.mode()
	local query = (mode == "v" or mode == "V" or mode == "\22") and visual_selection() or vim.fn.expand("<cword>")
	query = vim.trim(query or "")
	if query == "" then
		vim.notify("nothing under the cursor to search for", vim.log.levels.WARN)
		return
	end
	-- rg treats the query as a regex, so a symbol like `foo(` or `a.b` would misbehave;
	-- escape it. The Lua fallback matches literally, so it needs no escaping.
	if USE_RG then
		query = query:gsub("[%^%$%(%)%.%[%]%*%+%-%?{}|\\/]", "\\%1")
	end
	-- Seed the live picker rather than freezing the pattern, so you can refine it.
	live_grep(query)
end

---Repository root for `dir`, or nil when not inside a work tree. Distinct from root()
---above, which stops at pyproject.toml -- git status paths are relative to the REPO.
local function git_root(dir)
	local out = vim.fn.systemlist({ "git", "-C", dir, "rev-parse", "--show-toplevel" })
	if vim.v.shell_error ~= 0 or not out[1] then
		return nil
	end
	return vim.fs.normalize(out[1])
end

---Staged, unstaged and untracked files, from one `git status --porcelain -z`.
---
---The -z form is NUL-separated and unquoted, so paths with spaces, quotes or non-ASCII
---survive intact -- unlike the default output, which escapes them per core.quotepath.
function M.git_files()
	local repo = git_root(root())
	if not repo then
		vim.notify("not a git repository", vim.log.levels.WARN)
		return
	end

	local out = vim.fn.system({ "git", "-C", repo, "status", "--porcelain", "-z" })
	if vim.v.shell_error ~= 0 then
		vim.notify("git status failed", vim.log.levels.ERROR)
		return
	end

	local items = {}
	-- vim.fn.system() cannot return NUL bytes -- Vim strings are NUL-terminated -- so it
	-- substitutes SOH (0x01). Detect which separator actually came back rather than
	-- assuming, so this keeps working if that ever changes or vim.system() is used here.
	local nul = out:find("\0", 1, true) and "\0" or "\1"
	local parts = vim.split(out, nul, { plain = true })
	local i = 1
	while i <= #parts do
		local entry = parts[i]
		if entry ~= "" then
			local xy = entry:sub(1, 2)
			items[#items + 1] = { xy = xy, file = entry:sub(4), untracked = xy == "??" }
			-- A rename entry is followed by a second NUL-terminated field: the old path.
			if xy:sub(1, 1) == "R" then
				i = i + 1
			end
		end
		i = i + 1
	end

	if #items == 0 then
		vim.notify("working tree clean", vim.log.levels.INFO)
		return
	end

	local function abs(item)
		return vim.fs.normalize(repo .. "/" .. item.file)
	end

	pick({
		prompt = "git changes",
		items = items,
		-- Porcelain codes kept as-is: 'M ' staged, ' M' unstaged, 'MM' both, '??' untracked.
		format = function(i2)
			return ("%s %s"):format(i2.xy, i2.file)
		end,
		preview = function(i2)
			if i2.untracked then
				return file_preview(abs(i2), 1)
			end
			-- vs HEAD, so a file that is both staged and unstaged shows all of its changes.
			local diff = vim.fn.systemlist({ "git", "-C", repo, "diff", "HEAD", "--", i2.file })
			if vim.v.shell_error ~= 0 or #diff == 0 then
				return file_preview(abs(i2), 1)
			end
			-- ft=diff gets the built-in syntax file; no treesitter needed for +/- colouring.
			return { lines = diff, ft = "diff", lnum = 1 }
		end,
		path = abs,
		on_choice = function(i2, action)
			vim.cmd[action](vim.fn.fnameescape(abs(i2)))
		end,
	})
end

---Changed hunks in the CURRENT file, from `git diff HEAD`.
---
---Diffs the file as saved on disk, so unsaved edits are not represented -- the prompt
---says so when the buffer is modified, rather than quietly showing stale hunks.
function M.git_hunks()
	local file = vim.api.nvim_buf_get_name(0)
	if file == "" then
		vim.notify("buffer has no file path", vim.log.levels.WARN)
		return
	end
	local repo = git_root(vim.fs.dirname(file))
	if not repo then
		vim.notify("not a git repository", vim.log.levels.WARN)
		return
	end

	local win = vim.api.nvim_get_current_win()
	local modified = vim.bo.modified

	-- vs HEAD so staged and unstaged changes both appear.
	--
	-- -U0 is deliberate: with git's default 3 lines of context, edits within a few lines
	-- of each other are merged into one hunk, which is right for reading a patch and
	-- wrong for a picker -- three separate changes would collapse into a single entry you
	-- cannot jump between. Zero context makes every contiguous change its own hunk.
	local out = vim.fn.systemlist({ "git", "-C", repo, "diff", "-U0", "HEAD", "--", file })
	if vim.v.shell_error ~= 0 then
		vim.notify("git diff failed", vim.log.levels.ERROR)
		return
	end

	local hunks, current = {}, nil
	for _, line in ipairs(out) do
		-- @@ -old,count +new,count @@ trailing section heading (git's function context)
		local new_start, context = line:match("^@@ %-%d+,?%d* %+(%d+),?%d* @@ ?(.*)$")
		if new_start then
			current = {
				lnum = math.max(1, tonumber(new_start)),
				context = vim.trim(context),
				added = 0,
				removed = 0,
				lines = { line },
			}
			hunks[#hunks + 1] = current
		elseif current then
			-- Everything before the first @@ is the diff header; `current` is still nil there.
			current.lines[#current.lines + 1] = line
			local kind = line:sub(1, 1)
			if kind == "+" then
				current.added = current.added + 1
			elseif kind == "-" then
				current.removed = current.removed + 1
			end
		end
	end

	if #hunks == 0 then
		vim.notify(
			modified and "no changes on disk (buffer has unsaved edits)" or "no changes in this file",
			vim.log.levels.INFO
		)
		return
	end

	pick({
		prompt = modified and "Git hunks (unsaved edits not shown)" or "Git hunks",
		items = hunks,
		format = function(h)
			return ("%4d  +%d -%d  %s"):format(h.lnum, h.added, h.removed, h.context)
		end,
		preview = function(h)
			return { lines = h.lines, ft = "diff", lnum = 1 }
		end,
		on_choice = function(h, action)
			-- <CR> navigates within the file you are already in; a split/tab override reopens
			-- it elsewhere, matching buffer_lines.
			if action ~= DEFAULT_ACTION then
				vim.cmd[action](vim.fn.fnameescape(file))
			else
				vim.api.nvim_set_current_win(win)
			end
			pcall(vim.api.nvim_win_set_cursor, 0, { h.lnum, 0 })
			vim.cmd("normal! zz")
		end,
	})
end

---Fuzzy find lines in the current buffer. Captures the buffer and window up front, since
---opening the picker changes both.
function M.buffer_lines()
	local buf = vim.api.nvim_get_current_buf()
	local win = vim.api.nvim_get_current_win()
	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	local ft = vim.bo[buf].filetype

	local items = {}
	for lnum, text in ipairs(lines) do
		if vim.trim(text) ~= "" then
			items[#items + 1] = { lnum = lnum, text = text }
		end
	end

	pick({
		prompt = "Buffer lines",
		items = items,
		format = function(i)
			return ("%4d  %s"):format(i.lnum, i.text)
		end,
		-- The buffer is already in memory, so preview from the snapshot rather than disk.
		preview = function(i)
			return { lines = lines, ft = ft, lnum = i.lnum }
		end,
		on_choice = function(i, action)
			local name = vim.api.nvim_buf_get_name(buf)
			-- <CR> navigates within the buffer you are already in; only an explicit
			-- split/tab override reopens the file somewhere else.
			if action ~= DEFAULT_ACTION and name ~= "" then
				vim.cmd[action](vim.fn.fnameescape(name))
				pcall(vim.api.nvim_win_set_cursor, 0, { i.lnum, 0 })
			else
				vim.api.nvim_set_current_win(win)
				pcall(vim.api.nvim_win_set_cursor, win, { i.lnum, 0 })
			end
			vim.cmd("normal! zz")
		end,
	})
end

-- Exported so other modules can build their own pickers on the same widget rather than
-- falling back to vim.ui.select, which without a plugin is a numbered command-line
-- prompt. See browse_breakpoints in core/pydebug.lua.
M.pick = pick
M.file_preview = file_preview

vim.keymap.set("n", "<leader>sf", M.files, { desc = "[S]earch [F]iles" })
vim.keymap.set("n", "<leader>sg", M.grep, { desc = "[S]earch by [G]rep" })
vim.keymap.set({ "n", "x" }, "<leader>sw", M.grep_word, { desc = "[S]earch current [W]ord" })
vim.keymap.set("n", "<leader>sb", M.buffers, { desc = "[S]earch [B]uffers" })
vim.keymap.set("n", "<leader>gs", M.git_files, { desc = "[G]it [S]tatus -- changed files" })
vim.keymap.set("n", "<leader>g/", M.git_hunks, { desc = "[G]it [H]unks in the current file" })
vim.keymap.set("n", "<leader>/", M.buffer_lines, { desc = "Fuzzily search in current buffer" })

return M
