local M = {}

-- Ported from the plugin config for restricted environments: the original pulled in
-- utils.url / utils.str / utils.ui, none of which exist here. Everything below is
-- self-contained -- the module still only shells out to `git`, nothing else.

-- ---------------------------------------------------------------------------
-- Forges: which hosts get a clickable commit URL, and how that URL is shaped.
--
-- ADD YOUR ENTERPRISE HOST HERE. Entries are tried in order and the first whose host
-- appears in `git config --get remote.origin.url` wins, so put specific hosts above
-- generic ones. The url template receives (host, repo_path, commit_hash).
--
-- Path shapes differ by product, not by domain:
--   GitHub / GitHub Enterprise   https://HOST/owner/repo/commit/HASH
-- ---------------------------------------------------------------------------
local FORGES = {
	{ host = "github.com", url = "https://%s/%s/commit/%s" },
	{ host = "alm-github.systems.u.hsbc", url = "https://%s/%s/-/commit/%s" },
}

---Escape Lua pattern magic characters -- host names contain dots, which would otherwise
---match any character and make 'github.com' also match 'githubXcom'.
local function pattern_escape(text)
	return (text:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%1"))
end

---Build a web URL for `commit_hash` from the repo's origin remote.
---Handles the three remote spellings: git@host:path, https://host/path and
---ssh://git@host:PORT/path. Returns '' when the host matches no entry in FORGES.
local function commit_web_url(remote_url, commit_hash)
	for _, forge in ipairs(FORGES) do
		local host = pattern_escape(forge.host)
		local repo_path = remote_url:match(host .. "[:/](.+)%.git$") or remote_url:match(host .. "[:/](.+)$")
		if repo_path and repo_path ~= "" then
			-- ssh://git@host:7999/proj/repo leaves the port in the capture; drop it.
			repo_path = repo_path:gsub("^%d+/", "")
			return string.format(forge.url, forge.host, repo_path, commit_hash)
		end
	end
	return ""
end

-- Border style for the float. Matches BORDER in core/picker.lua.
local BORDER_STYLE = "single"
local BORDER_CORNERS = {
	rounded = { "\u{256D}", "\u{2500}", "\u{256E}", "\u{2502}", "\u{256F}", "\u{2500}", "\u{2570}", "\u{2502}" },
	single = { "\u{250C}", "\u{2500}", "\u{2510}", "\u{2502}", "\u{2518}", "\u{2500}", "\u{2514}", "\u{2502}" },
	double = { "\u{2554}", "\u{2550}", "\u{2557}", "\u{2551}", "\u{255D}", "\u{2550}", "\u{255A}", "\u{2551}" },
}

local ui = {
	BORDER = BORDER_CORNERS[BORDER_STYLE],
	---Link `name` to the first candidate highlight group that actually exists.
	link_first = function(name, candidates)
		for _, group in ipairs(candidates) do
			if vim.fn.hlexists(group) == 1 then
				vim.api.nvim_set_hl(0, name, { link = group })
				return true
			end
		end
		return false
	end,
}

---vim.trim does not strip \r, which git porcelain output can carry.
local function trim(value)
	if not value then
		return ""
	end
	return (value:gsub("\r", "")):gsub("^%s+", ""):gsub("%s+$", "")
end

-- Opening a URL: vim.ui.open (0.10+) hands off to the system handler. On a locked-down
-- box there may be no handler and no browser at all, so fall back to putting the URL in
-- the + and " registers and telling you -- copying it out beats a silent no-op.
local url_utils = {
	open_url_in_browser = function(url)
		local ok = vim.ui and vim.ui.open and pcall(vim.ui.open, url)
		if not ok then
			pcall(vim.fn.setreg, "+", url)
			vim.fn.setreg('"', url)
			vim.notify("no URL handler; copied to clipboard:\n" .. url, vim.log.levels.INFO)
		end
	end,
}

local function wrap_text(text, max_width)
	if not text or text == "" then
		return { "" }
	end

	max_width = math.max(max_width or 1, 1)

	local lines = {}
	local current = ""

	for word in text:gmatch("%S+") do
		if current == "" then
			current = word
		elseif #current + 1 + #word <= max_width then
			current = current .. " " .. word
		else
			table.insert(lines, current)
			if #word > max_width then
				local start_idx = 1
				while start_idx <= #word do
					local chunk = word:sub(start_idx, start_idx + max_width - 1)
					if #chunk == max_width then
						table.insert(lines, chunk)
						start_idx = start_idx + max_width
					else
						current = chunk
						start_idx = #word + 1
					end
				end
			else
				current = word
			end
		end
	end

	if current ~= "" then
		table.insert(lines, current)
	end

	return lines
end

local url_highlight_ns = vim.api.nvim_create_namespace("GitBlameFloatURL")
local float_highlight_ns = vim.api.nvim_create_namespace("GitBlameFloatLineHL")

local function normalize_path(path)
	if vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1 then
		return path:gsub("\\", "/")
	end
	return path
end

local function get_git_root_for_path(file_path)
	local dir = vim.fn.fnamemodify(file_path, ":h")
	local output = vim.fn.systemlist({ "git", "-C", dir, "rev-parse", "--show-toplevel" })
	if vim.v.shell_error ~= 0 or not output[1] or output[1] == "" then
		return nil
	end
	return trim(output[1])
end

local function relative_to_root(file_path, git_root)
	local normalized_file = normalize_path(file_path)
	local normalized_root = normalize_path(git_root)
	if normalized_file:sub(1, #normalized_root) == normalized_root then
		local offset = #normalized_root + 1
		if normalized_file:sub(offset, offset) == "/" then
			offset = offset + 1
		end
		return normalized_file:sub(offset)
	end
	return normalized_file
end

local function open_lazygit_for_commit(opts)
	opts = opts or {}
	local commit_hash = opts.commit_hash
	local file_path = opts.file_path

	if not commit_hash or commit_hash == "" or not file_path or file_path == "" then
		return
	end

	local ok, lazygit = pcall(require, "lazygit")
	if not ok or not lazygit or not lazygit.lazygitfilter then
		vim.notify("LazyGit plugin is not available", vim.log.levels.WARN)
		return
	end

	local git_root = get_git_root_for_path(file_path)
	if not git_root then
		vim.notify("Failed to determine git root for LazyGit", vim.log.levels.ERROR)
		return
	end

	local relative_path = relative_to_root(file_path, git_root)

	lazygit.lazygitfilter(relative_path, git_root)

	local search_hash = commit_hash:sub(1, math.min(#commit_hash, 8))
	local attempts = 0
	local max_attempts = 25

	local function focus_commit()
		attempts = attempts + 1
		local buf = rawget(_G, "LAZYGIT_BUFFER")
		if not buf or not vim.api.nvim_buf_is_valid(buf) then
			if attempts < max_attempts then
				vim.defer_fn(focus_commit, 100)
			end
			return
		end

		local ok_job, job_id = pcall(vim.api.nvim_buf_get_var, buf, "terminal_job_id")
		if not ok_job or not job_id then
			if attempts < max_attempts then
				vim.defer_fn(focus_commit, 100)
			end
			return
		end

		vim.api.nvim_chan_send(job_id, "/" .. search_hash .. "\r")
	end

	vim.defer_fn(focus_commit, 250)
end

local function ensure_url_highlight_group()
	if vim.fn.hlexists("GitBlameURL") == 0 then
		-- follow the theme's underlined/link color instead of hardcoding blue
		if not ui.link_first("GitBlameURL", { "@markup.link.url", "Underlined", "DiagnosticInfo" }) then
			vim.api.nvim_set_hl(0, "GitBlameURL", { underline = true })
		end
	end
end

local function open_float_window(content, opts)
	opts = opts or {}
	local web_url = opts.web_url or ""
	local help_text = opts.help_text
	local copy_text = opts.copy_text
	local close_keys = opts.close_keys or { "q", "<Esc>", "<CR>" }
	local highlight_regions = opts.highlights or {}
	local line_highlights = opts.line_highlights or {}
	local extra_keymaps = opts.extra_keymaps or {}
	local float_title = opts.title or ""
	local title_pos = opts.title_pos or "left"

	local lines = {}
	for _, line in ipairs(content) do
		table.insert(lines, line)
	end

	local help_line_index
	if help_text then
		table.insert(lines, "")
		table.insert(lines, help_text)
		help_line_index = #lines - 1
	end

	local width = 0
	for _, line in ipairs(lines) do
		width = math.max(width, #line)
	end
	width = width
	local height = #lines

	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

	local border_chars = ui.BORDER

	local base_opts = {
		relative = "cursor",
		row = 1,
		col = 0,
		width = width,
		height = height,
		style = "minimal",
		border = border_chars,
		focusable = true,
	}

	if float_title ~= "" then
		base_opts.title = float_title
		base_opts.title_pos = title_pos
	end

	local win = vim.api.nvim_open_win(
		buf,
		true,
		opts.win_opts and vim.tbl_extend("force", base_opts, opts.win_opts) or base_opts
	)

	vim.api.nvim_buf_set_option(buf, "buftype", "nofile")
	vim.api.nvim_win_set_option(win, "cursorline", false)
	vim.api.nvim_win_set_option(win, "cursorcolumn", false)

	for _, key in ipairs(close_keys) do
		vim.api.nvim_buf_set_keymap(buf, "n", key, "", {
			noremap = true,
			silent = true,
			callback = function()
				vim.api.nvim_win_close(win, true)
			end,
		})
	end

	if web_url ~= "" then
		vim.api.nvim_buf_set_keymap(buf, "n", "o", "", {
			noremap = true,
			silent = true,
			callback = function()
				url_utils.open_url_in_browser(web_url)
			end,
		})
	end

	if copy_text and copy_text ~= "" then
		vim.api.nvim_buf_set_keymap(buf, "n", "c", "", {
			noremap = true,
			silent = true,
			callback = function()
				vim.fn.setreg('"', copy_text)
				pcall(vim.fn.setreg, "+", copy_text)
				pcall(vim.fn.setreg, "*", copy_text)
				vim.notify("Commit hash copied to clipboard", vim.log.levels.INFO)
			end,
		})
	end

	for _, mapping in ipairs(extra_keymaps) do
		if mapping.key and mapping.callback then
			vim.keymap.set("n", mapping.key, function()
				mapping.callback(buf, win)
			end, {
				buffer = buf,
				noremap = true,
				silent = true,
				nowait = mapping.nowait ~= false,
			})
		end
	end

	local hl_exists = vim.fn.hlexists("GitBlameFloat") == 1
	if hl_exists then
		vim.api.nvim_win_set_option(win, "winhl", "Normal:GitBlameFloat,FloatBorder:GitBlameFloatBorder")
	else
		vim.api.nvim_win_set_option(win, "winhl", "Normal:NormalFloat,FloatBorder:FloatBorder")
	end

	vim.api.nvim_buf_set_option(buf, "modifiable", false)

	if #highlight_regions > 0 then
		ensure_url_highlight_group()
		for _, region in ipairs(highlight_regions) do
			vim.hl.range(
				buf,
				url_highlight_ns,
				region.group or "GitBlameURL",
				{ region.line, region.col_start },
				{ region.line, region.col_end },
				{}
			)
		end
	end

	if #line_highlights > 0 then
		for _, hl in ipairs(line_highlights) do
			if hl.group and vim.fn.hlexists(hl.group) == 1 then
				local line_text = content[hl.line + 1] or ""
				local start_col = hl.col_start or 0
				local end_col = hl.col_end

				if not end_col or end_col < 0 then
					end_col = #line_text
				end

				vim.hl.range(buf, float_highlight_ns, hl.group, { hl.line, start_col }, { hl.line, end_col }, {})
			end
		end
	end

	if help_line_index and opts.help_highlight and vim.fn.hlexists(opts.help_highlight) == 1 then
		vim.hl.range(
			buf,
			float_highlight_ns,
			opts.help_highlight,
			{ help_line_index, 0 },
			{ help_line_index, #help_text },
			{}
		)
	end
end

function M.show_git_blame_float()
	local current_line = vim.fn.line(".")
	local file_path = vim.fn.expand("%:p")

	local git_root = get_git_root_for_path(file_path)
	if not git_root then
		vim.notify("Not in a git repository", vim.log.levels.ERROR)
		return
	end

	local blame_cmd = string.format(
		"git -C %s blame -L %d,%d --porcelain -- %s",
		vim.fn.shellescape(git_root),
		current_line,
		current_line,
		vim.fn.shellescape(file_path)
	)
	local blame_output = vim.fn.system(blame_cmd)

	if vim.v.shell_error ~= 0 then
		if blame_output:match("fatal: no such path") then
			local help_text = "Press 'q' or <Esc> to close"
			open_float_window(
				{ string.format("󰙚 %s is still cooking!", vim.fn.fnamemodify(file_path, ":t:r")) },
				{ help_text = help_text }
			)
			return
		end

		vim.notify("Failed to get git blame info", vim.log.levels.ERROR)
		return
	end

	local lines = vim.split(blame_output, "\n")
	local commit_hash = lines[1]:match("^(%x+)")

	if not commit_hash or commit_hash == "0000000000000000000000000000000000000000" then
		vim.notify("No commit info for this line", vim.log.levels.WARN)
		return
	end

	local commit_stat_cmd = string.format("git -C %s show --stat %s", vim.fn.shellescape(git_root), commit_hash)
	local commit_stat = vim.fn.system(commit_stat_cmd)

	if vim.v.shell_error ~= 0 then
		vim.notify("Failed to get commit stats", vim.log.levels.ERROR)
		return
	end

	local commit_info_cmd = string.format(
		'git -C %s show --no-patch --format="%%an|%%ae|%%ad|%%s" --date=format:"%%Y-%%m-%%d %%H:%%M:%%S" %s',
		vim.fn.shellescape(git_root),
		commit_hash
	)
	local commit_info = vim.fn.system(commit_info_cmd)

	if vim.v.shell_error ~= 0 then
		vim.notify("Failed to get commit details", vim.log.levels.ERROR)
		return
	end

	local author, email, date, message = commit_info:match("^([^|]+)|([^|]+)|([^|]+)|(.+)")
	local files_changed, insertions, deletions
	local full_files, full_insertions, full_deletions =
		commit_stat:match("(%d+) files? changed[, ]+(%d+) insertions?%(%+%)?,?[, ]*(%d+) deletions?%(-%)?")
	if full_files then
		files_changed, insertions, deletions = full_files, full_insertions, full_deletions
	else
		local files_insert_only, insert_only_count =
			commit_stat:match("(%d+) files? changed[, ]+(%d+) insertions?%(%+%)?")
		if files_insert_only then
			files_changed, insertions = files_insert_only, insert_only_count
		else
			local files_delete_only, delete_only_count =
				commit_stat:match("(%d+) files? changed[, ]*(%d+) deletions?%(-%)?")
			if files_delete_only then
				files_changed, deletions = files_delete_only, delete_only_count
			end
		end
	end

	local remote_url_cmd = string.format("git -C %s config --get remote.origin.url", vim.fn.shellescape(git_root))
	local remote_url = vim.fn.system(remote_url_cmd):gsub("\n", "")

	local web_url = commit_web_url(remote_url, commit_hash)

	local content = {}
	local line_highlights = {}

	local function append_line(value, highlight)
		table.insert(content, value)
		local line_index = #content - 1
		if highlight then
			table.insert(line_highlights, {
				line = line_index,
				group = highlight,
			})
		end
		return line_index
	end

	append_line("", nil)
	append_line(string.format("  %s <%s> on %s", author, email, date), "GitBlameFloatAuthor")
	append_line("", nil)

	local sanitized_message = message:gsub("\r", " "):gsub("\n", " "):gsub("%s+", " ")
	local max_message_width = math.max(40, math.min(100, math.floor(200 * 0.5)))
	local message_indent = "   "
	local wrapped_message = wrap_text(sanitized_message, math.max(max_message_width - #message_indent, 10))
	for _, line in ipairs(wrapped_message) do
		append_line(message_indent .. line, "GitBlameFloatMessage")
	end
	append_line("", nil)
	local commit_hash_display = string.format("  %s", commit_hash:sub(1, 8))
	local hash_url_line = commit_hash_display
	if web_url ~= "" then
		hash_url_line = hash_url_line .. string.format(" |   %s", web_url)
	end

	local highlights = {}
	local hash_line_index = append_line(hash_url_line, nil)

	local hash_display_start = hash_url_line:find(commit_hash_display, 1, true)
	if hash_display_start then
		table.insert(line_highlights, {
			line = hash_line_index,
			group = "GitBlameFloatHash",
			col_start = hash_display_start - 1,
			col_end = (hash_display_start - 1) + #commit_hash_display,
		})
	end
	append_line("", nil)

	if files_changed then
		local stats_segments = {}
		table.insert(stats_segments, {
			text = " " .. string.format("%s files changed", files_changed),
			group = "GitBlameFloatStatsFilesChanged",
		})

		if insertions then
			table.insert(stats_segments, {
				text = ", ",
				group = nil,
			})
			table.insert(stats_segments, {
				text = string.format("+%s insertions", insertions),
				group = "GitBlameFloatStatsInsertions",
			})
		end

		if deletions then
			table.insert(stats_segments, {
				text = ", ",
				group = nil,
			})
			table.insert(stats_segments, {
				text = string.format("-%s deletions", deletions),
				group = "GitBlameFloatStatsDeletions",
			})
		end

		local stats_line = ""
		for _, segment in ipairs(stats_segments) do
			stats_line = stats_line .. segment.text
		end

		local stats_line_index = append_line(stats_line, nil)

		local col = 0
		for _, segment in ipairs(stats_segments) do
			local segment_length = #segment.text
			if segment.group then
				table.insert(line_highlights, {
					line = stats_line_index,
					group = segment.group,
					col_start = col,
					col_end = col + segment_length,
				})
			end
			col = col + segment_length
		end
	end

	if web_url ~= "" then
		local url_start = hash_url_line:find(web_url, 1, true)
		if url_start then
			table.insert(highlights, {
				line = hash_line_index,
				col_start = url_start - 1,
				col_end = (url_start - 1) + #web_url,
				group = "GitBlameURL",
			})
		end
	end

	local help_text
	if web_url ~= "" then
		help_text = " Press 'o' to open URL, 'd' to view diff on lazygit, 'c' to copy hash and q' or <Esc> to quit"
	else
		help_text = " Press 'd' to view diff on lazygit, 'c' to copy hash and q' or <Esc> to quit"
	end

	local git_blame_icon_hl = "GitBlameFloatTitleIcon"
	local icon = "󰊢"
	local title = {
		{ " " .. icon .. " ", git_blame_icon_hl },
		{ "git blame ", "GitBlameFloatTitle" },
	}

	open_float_window(content, {
		web_url = web_url,
		help_text = help_text,
		copy_text = commit_hash,
		highlights = highlights,
		line_highlights = line_highlights,
		help_highlight = "GitBlameFloatHelp",
		title = title,
		title_pos = "left",
		extra_keymaps = {
			{
				key = "d",
				callback = function(_, win)
					if vim.api.nvim_win_is_valid(win) then
						vim.api.nvim_win_close(win, true)
					end
					open_lazygit_for_commit({
						commit_hash = commit_hash,
						file_path = file_path,
						line = current_line,
					})
				end,
			},
		},
	})
end

-- The original registered this inside the gitsigns config block; standalone here.
vim.keymap.set("n", "<leader>gb", function()
	M.show_git_blame_float()
end, { desc = "[G]it [B]lame floating window" })

return M
