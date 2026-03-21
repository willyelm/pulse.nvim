local M = {}
M.__index = M
local window = require("pulse.ui.window")

local function normalise_lines(lines)
	local out = {}
	for _, line in ipairs(lines or {}) do
		for _, part in ipairs(vim.split(tostring(line or ""), "\n", { plain = true, trimempty = false })) do
			out[#out + 1] = part
		end
	end
	return out
end

local function add_hl(highlights, group, row, start_col, end_col, priority)
	highlights[#highlights + 1] =
		{ group = group, row = row, start_col = start_col, end_col = end_col, priority = priority }
end

local function add_query_matches(highlights, lines, query)
	local q = (query or ""):lower()
	if q == "" then
		return
	end
	for row, text in ipairs(lines) do
		local lower, from = (text or ""):lower(), 1
		while true do
			local idx = lower:find(q, from, true)
			if not idx then
				break
			end
			add_hl(highlights, "Search", row - 1, idx - 1, idx - 1 + #q)
			from = idx + 1
		end
	end
end

local function file_snippet(path, lnum, query, match_cols)
	local resolved = (path and vim.fn.filereadable(path) == 1) and path or vim.fn.fnamemodify(path or "", ":p")
	if vim.fn.filereadable(resolved) ~= 1 then
		return { "File not found: " .. tostring(path) }, "text", {}, nil, 1
	end
	local file_lines = vim.fn.readfile(resolved)
	local line_no = math.max(lnum or 1, 1)
	local start_l, end_l = math.max(line_no - 6, 1), math.min(#file_lines, line_no + 6)
	local lines, highlights, numbers = {}, {}, {}
	for i = start_l, end_l do
		lines[#lines + 1] = file_lines[i] or ""
		numbers[#numbers + 1] = i
	end
	add_query_matches(highlights, lines, query)
	if type(match_cols) == "table" then
		local row = line_no - start_l
		for _, col in ipairs(match_cols) do
			if type(col) == "number" and col > 0 then
				highlights[#highlights + 1] = { group = "Search", row = row, start_col = col - 1, end_col = col }
			end
		end
	end
	local ft = vim.filetype.match({ filename = resolved or "" })
	local filetype = (ft and ft ~= "") and ft or (vim.fn.fnamemodify(resolved or "", ":e") ~= "" and vim.fn.fnamemodify(resolved or "", ":e") or "file")
	return lines, filetype, highlights, numbers, (line_no - start_l + 1)
end

M.file_snippet = file_snippet

function M.new(opts)
	local self = setmetatable({}, M)
	self.buf = assert(opts.buf, "context requires a buffer")
	self.win = assert(opts.win, "context requires a window")
	self.ns = vim.api.nvim_create_namespace("pulse_ui_context")
	self.active_filetype = "text"
	vim.bo[self.buf].buftype, vim.bo[self.buf].bufhidden, vim.bo[self.buf].buflisted, vim.bo[self.buf].swapfile =
		"nofile", "hide", false, false
	vim.bo[self.buf].modifiable, vim.bo[self.buf].filetype = false, "text"
	window.configure_content_window(self.win)
	return self
end

function M:set_target(buf, win)
	self.buf, self.win = buf, win
	if self.win and vim.api.nvim_win_is_valid(self.win) then
		window.configure_content_window(self.win)
	end
end

function M:set(lines, filetype, highlights, line_numbers, focus_row)
	if not (self.buf and vim.api.nvim_buf_is_valid(self.buf)) then
		return
	end
	vim.bo[self.buf].modifiable = true
	vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, normalise_lines(lines))
	vim.bo[self.buf].modifiable = false
	vim.bo[self.buf].modified = false

	local ft = filetype or "text"
	vim.bo[self.buf].filetype = ft
	vim.api.nvim_buf_clear_namespace(self.buf, self.ns, 0, -1)
	if ft ~= self.active_filetype then
		self.active_filetype = ft
		if ft ~= "" and ft ~= "text" then
			pcall(vim.treesitter.start, self.buf, ft)
		end
	end

	if line_numbers and #line_numbers > 0 then
		local max_line = 0
		for _, n in ipairs(line_numbers) do
			if type(n) == "number" and n > max_line then
				max_line = n
			end
		end
		local w = math.max(#tostring(max_line), 1)
		for row, n in ipairs(line_numbers) do
			if type(n) == "number" then
				vim.api.nvim_buf_set_extmark(self.buf, self.ns, row - 1, 0, {
					virt_text = { { string.format("%" .. w .. "d ", n), "LineNr" } },
					virt_text_pos = "inline",
				})
			end
		end
	end

	for _, hl in ipairs(highlights or {}) do
		local opts = { hl_group = hl.group, hl_mode = hl.hl_mode or "replace" }
		if hl.end_col and hl.end_col >= 0 then
			opts.end_row = hl.row
			opts.end_col = hl.end_col
		end
		if hl.priority then opts.priority = hl.priority end
		pcall(vim.api.nvim_buf_set_extmark, self.buf, self.ns, hl.row, hl.start_col, opts)
	end

	if self.win and vim.api.nvim_win_is_valid(self.win) then
		window.configure_content_window(self.win)
		pcall(vim.api.nvim_win_set_cursor, self.win, { math.max(focus_row or 1, 1), 0 })
		pcall(vim.api.nvim_win_call, self.win, function()
			vim.cmd("normal! zz")
		end)
	end
end

return M
