-- Python debugging without nvim-dap.
--
-- Neovim has no Debug Adapter Protocol support, so there is no plugin-free equivalent
-- of nvim-dap / nvim-dap-view. This drives ipdb in the terminal split instead, manages
-- breakpoints through a project-local `.pdbrc`, and follows execution in your buffers by
-- watching what the debugger prints.

local term = require("core.terminal")

-- Must be importable BY THE ENVIRONMENT being debugged -- debuggers import your code,
-- so a pipx install cannot work. 'pdb' is the zero-install stdlib fallback.
local DEBUGGER = "ipdb"
local DEBUG_HEIGHT = 25

vim.env.IPDB_CONTEXT_SIZE = "15"
vim.env.PYTHONBREAKPOINT = DEBUGGER .. ".set_trace"

-- Plain Unicode, deliberately: these render in any terminal font and need no patched
-- Nerd Font. U+25C9 / U+25CE / U+00BB.
vim.fn.sign_define("PyBreakpoint", { text = "\u{25CF}", texthl = "DiagnosticError" })
vim.fn.sign_define("PyBreakpointCond", { text = "\u{25C6}", texthl = "DiagnosticWarn" })
vim.fn.sign_define("PyDebugCurrent", { text = "\u{2192}", texthl = "DiagnosticWarn", linehl = "Visual" })
local SIGN_GROUP = "pydebug"
local CURRENT_GROUP = "pydebug-current"
local ROOT_MARKERS = { "pyproject.toml", "setup.py", ".git" }

local function root()
	local found = vim.fs.find(ROOT_MARKERS, { upward = true, path = vim.fn.getcwd() })[1]
	return found and vim.fs.dirname(found) or vim.fn.getcwd()
end

local function pdbrc()
	return vim.fs.normalize(root() .. "/.pdbrc")
end

---Path as pdb should see it: relative to the root, forward slashes.
local function rel(path)
	local r, p = vim.fs.normalize(root()), vim.fs.normalize(path)
	if p:sub(1, #r + 1):lower() == (r .. "/"):lower() then
		return p:sub(#r + 2)
	end
	return p
end

local function read_lines()
	local f = pdbrc()
	if vim.fn.filereadable(f) == 0 then
		return {}
	end
	return vim.fn.readfile(f)
end

local function write_lines(lines)
	vim.fn.writefile(lines, pdbrc())
end

---Parse a `b path:lnum[, condition]` line. Returns file, lnum, condition.
local function parse(line)
	local body = line:match("^%s*b%s+(.+)$") or line:match("^%s*break%s+(.+)$")
	if not body then
		return nil
	end
	local spec, cond = body:match("^([^,]+),%s*(.+)$")
	spec = spec or body
	local file, lnum = spec:match("^(.*):(%d+)%s*$")
	if not file then
		return nil
	end
	return vim.trim(file), tonumber(lnum), cond and vim.trim(cond) or nil
end

local function refresh_signs(bufnr)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end
	vim.fn.sign_unplace(SIGN_GROUP, { buffer = bufnr })
	local name = vim.api.nvim_buf_get_name(bufnr)
	if name == "" then
		return
	end
	local want = rel(name):lower()
	for _, line in ipairs(read_lines()) do
		local file, lnum, cond = parse(line)
		if file and file:lower() == want then
			vim.fn.sign_place(
				0,
				SIGN_GROUP,
				cond and "PyBreakpointCond" or "PyBreakpoint",
				bufnr,
				{ lnum = lnum, priority = 20 }
			)
		end
	end
end

local function refresh_all()
	for _, b in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_loaded(b) and vim.bo[b].filetype == "python" then
			refresh_signs(b)
		end
	end
end

local function toggle_breakpoint(condition)
	local bufnr = vim.api.nvim_get_current_buf()
	local name = vim.api.nvim_buf_get_name(bufnr)
	if name == "" then
		vim.notify("buffer has no file path", vim.log.levels.WARN)
		return
	end
	local file, lnum = rel(name), vim.api.nvim_win_get_cursor(0)[1]

	local kept, removed = {}, false
	for _, line in ipairs(read_lines()) do
		local f, l = parse(line)
		if f and f:lower() == file:lower() and l == lnum then
			removed = true
		else
			kept[#kept + 1] = line
		end
	end
	if not removed then
		kept[#kept + 1] = condition and ("b %s:%d, %s"):format(file, lnum, condition) or ("b %s:%d"):format(file, lnum)
	end
	write_lines(kept)
	refresh_signs(bufnr)
end

local function clear_breakpoints()
	local kept, removed = {}, 0
	for _, line in ipairs(read_lines()) do
		if parse(line) then
			removed = removed + 1
		else
			kept[#kept + 1] = line -- preserve non-breakpoint pdb commands
		end
	end
	write_lines(kept)
	refresh_all()
	vim.notify(("removed %d breakpoint(s)"):format(removed), vim.log.levels.INFO)
end

---Browse breakpoints in the same picker widget the file/grep pickers use, so you get
---fuzzy filtering and a preview of the line each breakpoint actually sits on.
local function browse_breakpoints()
  local items = {}
  for _, line in ipairs(read_lines()) do
    local file, lnum, cond = parse(line)
    if file then
      items[#items + 1] = { file = file, lnum = lnum, cond = cond }
    end
  end
  if #items == 0 then
    vim.notify('no breakpoints set', vim.log.levels.INFO)
    return
  end

  local picker = require 'core.picker'
  local dir = root()

  local function abs(item)
    return vim.fs.normalize(dir .. '/' .. item.file)
  end

  picker.pick {
    prompt = 'Breakpoints',
    items = items,
    format = function(i)
      return ('%s:%d%s'):format(i.file, i.lnum, i.cond and ('  [' .. i.cond .. ']') or '')
    end,
    preview = function(i)
      return picker.file_preview(abs(i), i.lnum)
    end,
    -- Same <CR>/<C-t>/<C-v>/<C-x> verbs as every other picker.
    on_choice = function(i, action)
      vim.cmd[action](vim.fn.fnameescape(abs(i)))
      pcall(vim.api.nvim_win_set_cursor, 0, { i.lnum, 0 })
      vim.cmd 'normal! zz'
    end,
  }
end

local function insert_breakpoint_call()
	local bufnr = vim.api.nvim_get_current_buf()
	local lnum = vim.api.nvim_win_get_cursor(0)[1]
	local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""
	local indent = line:match("^(%s*)")
	if line:match(":%s*$") then
		indent = indent .. (vim.bo[bufnr].expandtab and string.rep(" ", vim.bo[bufnr].shiftwidth) or "\t")
	end
	vim.api.nvim_buf_set_lines(bufnr, lnum - 1, lnum - 1, false, { indent .. "breakpoint()" })
end

-- ---------------------------------------------------------------------------
-- Execution tracking.
--
-- pdb and ipdb print a location line every time they stop:
--     > /home/you/proj/app/models.py(42)process()
-- Neovim's terminal emulator has already stripped the ANSI escapes by the time the text
-- lands in the buffer, so we can watch for that line and mirror it into an editor
-- window. Focus deliberately stays in the terminal -- nvim_win_set_buf/set_cursor and
-- nvim_win_call all act on another window without making it current.
-- ---------------------------------------------------------------------------

local current = { buf = nil }

local function clear_current()
	if current.buf and vim.api.nvim_buf_is_valid(current.buf) then
		vim.fn.sign_unplace(CURRENT_GROUP, { buffer = current.buf })
	end
	current.buf = nil
end

---A window showing an ordinary file, i.e. not the terminal and not a float.
local function editor_win()
	for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
		local cfg = vim.api.nvim_win_get_config(win)
		local buf = vim.api.nvim_win_get_buf(win)
		if cfg.relative == "" and vim.bo[buf].buftype ~= "terminal" then
			return win
		end
	end
	return nil
end

---Show `path` at `lnum` in an editor window, without stealing focus.
local function show_location(path, lnum)
	if not vim.fs.normalize(path):match("^/") and not path:match("^%a:") then
		path = vim.fs.normalize(root() .. "/" .. path) -- pdb may print a relative path
	end
	if vim.fn.filereadable(path) == 0 then
		return -- <string>, a stdlib file outside the project, etc.
	end

	local win = editor_win()
	if not win then
		return
	end

	local buf = vim.fn.bufadd(path)
	vim.fn.bufload(buf)
	vim.bo[buf].buflisted = true

	if vim.api.nvim_win_get_buf(win) ~= buf then
		vim.api.nvim_win_set_buf(win, buf)
	end
	lnum = math.max(1, math.min(lnum, vim.api.nvim_buf_line_count(buf)))
	pcall(vim.api.nvim_win_set_cursor, win, { lnum, 0 })
	-- Centre it: 'zz' needs to run with that window current, which win_call does
	-- temporarily without changing where your keystrokes go.
	pcall(vim.api.nvim_win_call, win, function()
		vim.cmd("normal! zz")
	end)

	clear_current()
	current.buf = buf
	vim.fn.sign_place(0, CURRENT_GROUP, "PyDebugCurrent", buf, { lnum = lnum, priority = 30 })
	refresh_signs(buf)
end

---Watch a terminal buffer for pdb location lines.
local function track(bufnr)
	vim.api.nvim_buf_attach(bufnr, false, {
		on_lines = function(_, b, _, first, _, last)
			if not vim.api.nvim_buf_is_valid(b) then
				return true -- detach
			end
			-- on_lines runs in a fast context; no API calls until we are scheduled.
			vim.schedule(function()
				if not vim.api.nvim_buf_is_valid(b) then
					return
				end
				local lines = vim.api.nvim_buf_get_lines(b, first, math.max(last, first + 1), false)
				for i = #lines, 1, -1 do
					-- Lazy capture so a path containing '(' cannot swallow the line number.
					local file, lnum = lines[i]:match("^>%s+(.-)%((%d+)%)")
					if file and lnum then
						show_location(vim.trim(file), tonumber(lnum))
						return
					end
				end
			end)
		end,
	})
end

vim.api.nvim_create_autocmd("TermOpen", {
	group = vim.api.nvim_create_augroup("pydebug-track", { clear = true }),
	callback = function(args)
		track(args.buf)
	end,
})

vim.api.nvim_create_autocmd("TermClose", {
	group = "pydebug-track",
	callback = clear_current,
})

-- ---------------------------------------------------------------------------
-- Launching
-- ---------------------------------------------------------------------------

local importable = {}
local function debugger_available(py)
	if importable[py] == nil then
		vim.fn.system({ py, "-c", "import " .. DEBUGGER })
		importable[py] = vim.v.shell_error == 0
	end
	return importable[py]
end

local function interpreter()
	return require("core.lsp").venv_python() or "python"
end

local function save_if_needed()
	if vim.bo.modified then
		vim.cmd("write")
	end
end

local function debug_file()
	local file = vim.api.nvim_buf_get_name(0)
	if file == "" then
		vim.notify("buffer has no file path", vim.log.levels.WARN)
		return
	end
	local py = interpreter()
	if not debugger_available(py) then
		vim.notify(
			("%s is not importable by %s\nInstall it INTO this environment (pipx isolates, so it cannot work)"):format(
				DEBUGGER,
				py
			),
			vim.log.levels.ERROR
		)
		return
	end
	save_if_needed()
	-- cd to the root so pdb finds .pdbrc and resolves the relative paths in it.
	term.run(("cd %s"):format(vim.fn.fnameescape(root())))
	term.run(("%s -m %s %s"):format(py, DEBUGGER, vim.fn.fnameescape(file)), { height = DEBUG_HEIGHT })
end

local function run_file()
	local file = vim.api.nvim_buf_get_name(0)
	if file == "" then
		return
	end
	save_if_needed()
	term.run(("%s %s"):format(interpreter(), vim.fn.fnameescape(file)), { height = DEBUG_HEIGHT })
end

vim.keymap.set("n", "<leader>b", function()
	toggle_breakpoint(nil)
end, { desc = "Debug: Toggle [B]reakpoint" })

vim.keymap.set("n", "<leader>B", function()
	vim.ui.input({ prompt = "Breakpoint condition: " }, function(cond)
		if cond and cond ~= "" then
			toggle_breakpoint(cond)
		end
	end)
end, { desc = "Debug: Conditional [B]reakpoint" })

vim.keymap.set("n", "<leader>bb", browse_breakpoints, { desc = "Debug: [B]rowse [B]reakpoints" })
vim.keymap.set("n", "<leader>bi", insert_breakpoint_call, { desc = "Debug: [I]nsert breakpoint() call" })
vim.keymap.set("n", "<leader>bc", clear_breakpoints, { desc = "Debug: [C]lear all [B]reakpoints" })
vim.keymap.set("n", "<leader>dr", run_file, { desc = "[D]ebug: [R]un (stops at breakpoint() calls)" })
vim.keymap.set("n", "<leader>ds", debug_file, { desc = "[D]ebug: [S]tart under debugger" })

vim.api.nvim_create_autocmd({ "BufReadPost", "BufWritePost" }, {
	group = vim.api.nvim_create_augroup("pydebug-signs", { clear = true }),
	pattern = "*.py",
	callback = function(args)
		refresh_signs(args.buf)
	end,
})
